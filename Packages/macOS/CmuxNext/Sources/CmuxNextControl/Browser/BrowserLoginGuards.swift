import CmuxNextCompat
public import Foundation
import os

/// Sites (origins) an agent scripted and sites holding a filled Secure Store login, per browser
/// profile, kept across app restarts (cmux https://github.com/manaflow-ai/cmux/issues/25830). The
/// two exclude each other for good:
///
/// - Agent code on an origin whose sign-in was filled is refused (`eval`, `wait --function`,
///   storage and cookie writes, the browser host's `frame.evaluate`, raw DevTools), so no script
///   of that site's origin can read the password back.
/// - `fill_login` on an origin agent code ever ran on is refused: that code could have left a hook
///   behind in another tab of the origin, an opener handle or a service worker. So is a tab that
///   ever had a raw DevTools relay (it reaches every site that tab visits) or that a page opened,
///   and any tab of a profile while a raw DevTools relay is attached in it.
    /// - Raw DevTools (sessions reach other frames and targets) is all or nothing per profile: while
    ///   the profile holds ANY filled sign-in, no relay attaches and no raw message passes. Before
    ///   attaching, the whole profile is durably marked scripted, including after detach/restart.
///
/// An origin is `scheme://host[:port]` as `location.origin` gives it, keyed with the tab's
/// profile (each profile has its own storage and service workers). Check and mark happen in one
/// actor step, so agent code and a fill racing on one origin cannot both pass. ONE instance serves
/// the app (the composition root gives it to the control socket's page verbs and the browser
/// host's gate).
///
/// Fail closed: a guard file that exists but cannot be read refuses every fill
/// (`guard_unreadable`) and is never overwritten, until it is repaired (fixed or removed) and the
/// app starts again. A save that fails keeps the marks in memory and refuses fills on the origins
/// it held (`guard_unsaved`) until a save succeeds. The file is read once, on first use, and
/// written on each change, on this actor, never the main thread.
public actor BrowserLoginGuards {
    /// Whether a fill may run, and if not, why.
    public enum FillAdmission: String, Sendable {
        case admitted
        /// Agent code ran on the origin, or the tab had a raw DevTools relay.
        case scripted = "scripted_origin"
        /// A raw DevTools relay is attached to a tab of the profile.
        case rawAttached = "raw_devtools_attached"
        /// A page opened the tab: its opener's script could reach in.
        case openedByPage = "opened_by_page"
        case unreadable = "guard_unreadable"
        case unsaved = "guard_unsaved"
    }

    /// A fill's admission and its reservation. Finish each admitted attempt with
    /// ``completeFill(_:)`` or, only when it wrote nothing, ``forgetFill(_:)``.
    public struct Fill: Sendable {
        public let admission: FillAdmission
        public let added: Set<String>
        fileprivate let id: UUID?
    }

    private struct Saved: Codable {
        var scripted: [String]
        var filled: [String]
    }

    /// What the raw DevTools relay reads and writes without the actor, so it keeps message order
    /// and its marks count at once.
    private struct Mirror {
        /// The filled keys; nil until the file was read.
        var filled: Set<String>?
        /// Sites a raw relay reached, marked at once (persisted on the actor after).
        var rawScripted: Set<String> = []
        /// Attached raw relays: tab -> profile key prefix.
        var attached: [String: String] = [:]
    }

    private let mirrorState = Mutex(Mirror(filled: nil))

    private let file: URL?
    private var scripted: Set<String> = []
    private var filled: Set<String> = []
    /// Completed fills and marks restored from disk never roll back. Pending attempts protect
    /// their whole origin set, including origins another concurrent attempt first reserved.
    private var committedFills: Set<String> = []
    private var pendingFills: [UUID: Set<String>] = [:]
    /// Tabs that ever had a raw DevTools relay, and tabs a page opened (this run).
    private var rawTabs: Set<String> = []
    private var openedTabs: Set<String> = []
    /// The file exists but could not be read: no fill, no save.
    private var unreadable = false
    /// Keys a failed save held; no fill on their origins until a save succeeds.
    private var unsaved: Set<String> = []
    private var loaded = false
    private let log = Logger(subsystem: "com.cmuxterm.app.next", category: "browser-login-guards")

    /// - Parameter file: where the marks persist; nil keeps them in memory only.
    public init(file: URL?) {
        self.file = file
    }

    /// Agent code is about to run on a page of `origins` (nil: the origin could not be read;
    /// empty or containing `null`: an opaque/inherited page). Unpinnable origins reserve the
    /// entire profile against future fills and are refused while it already holds any fill.
    /// Otherwise false when one of the origins holds a fill; else each is marked scripted.
    public func beginScript(profile: String?, origins: [String]?) -> Bool {
        load()
        var origins = origins ?? []
        if origins.isEmpty || origins.contains("null") {
            guard !holdsFill(profile) else { return false }
            if !origins.contains("null") { origins.append("null") }
        }
        let keys = origins.map { Self.key(profile: profile, origin: $0) }
        if keys.contains(where: filled.contains) { return false }
        insertScripted(keys)
        // New persistent code cannot run until its exclusion survives a restart. Retry a
        // previously failed write, too: restoring the directory must allow a safe admission.
        if keys.contains(where: unsaved.contains) { save(changed: Set(keys)) }
        return !unreadable && !keys.contains(where: unsaved.contains)
    }

    /// Marks `origins` scripted after agent code ran (it may have moved to another site).
    public func markScripted(profile: String?, origins: [String]?) {
        load()
        insertScripted((origins ?? []).map { Self.key(profile: profile, origin: $0) })
    }

    /// Whether a page of `origins` (nil: unknown) may be captured (a screenshot, a PDF): not when
    /// one holds a filled login, nor, unknown, while the profile holds any.
    public func mayCapture(profile: String?, origins: [String]?) -> Bool {
        load()
        guard let origins else { return !holdsFill(profile) }
        return !origins.contains { filled.contains(Self.key(profile: profile, origin: $0)) }
    }

    /// A raw DevTools relay is about to attach to `tab` showing `origins`. False while the profile
    /// holds any filled login; else the origins are marked scripted, the tab never gets a fill,
    /// and no tab of the profile gets one while the relay stays attached (``rawDevToolsEnded(tab:)``).
    public func beginRawDevTools(tab: String, profile: String?, origins: [String]?) -> Bool {
        load()
        // A raw session reaches child frames and other targets without a trustworthy origin
        // notification. Reserve the whole profile durably before exposing that capability.
        guard beginScript(profile: profile, origins: ["null"] + (origins ?? [])) else { return false }
        rawTabs.insert(tab)
        let prefix = Self.key(profile: profile, origin: "")
        mirrorState.withLock { $0.attached[tab] = prefix }
        return true
    }

    /// The raw DevTools relay of `tab` ended (detached, closed).
    public nonisolated func rawDevToolsEnded(tab: String) {
        mirrorState.withLock { _ = $0.attached.removeValue(forKey: tab) }
    }

    /// A page opened `tab` (a popup): it never gets a fill.
    public func markOpenedByPage(tab: String) {
        openedTabs.insert(tab)
    }

    /// A login is about to be filled into `tab`, a page of `origins`. Refused when agent code ran
    /// on one of them (a raw relay's mark counts at once), the tab had a raw DevTools relay, a raw
    /// relay is attached in the profile, a page opened the tab, or the guard file cannot be read or
    /// saved; else each origin is marked filled and the answer names the marks it newly added.
    public func beginFill(tab: String, profile: String?, origins: [String]) -> Fill {
        load()
        func refused(_ admission: FillAdmission) -> Fill { Fill(admission: admission, added: [], id: nil) }
        if unreadable { return refused(.unreadable) }
        if openedTabs.contains(tab) { return refused(.openedByPage) }
        let keys = origins.map { Self.key(profile: profile, origin: $0) }
        let prefix = Self.key(profile: profile, origin: "")
        let (rawScripted, attached) = mirrorState.withLock { ($0.rawScripted, $0.attached.values.contains(prefix)) }
        if attached { return refused(.rawAttached) }
        if rawTabs.contains(tab) || scripted.contains(Self.key(profile: profile, origin: "null"))
            || keys.contains(where: { scripted.contains($0) || rawScripted.contains($0) }) {
            return refused(.scripted)
        }
        if keys.contains(where: unsaved.contains) { return refused(.unsaved) }
        let added = Set(keys).subtracting(filled)
        let id = UUID()
        pendingFills[id] = Set(keys)
        insertFilled(added)
        if keys.contains(where: unsaved.contains) {
            // No script may run after a failed persistence attempt. Keep the conservative marks,
            // but do not retain a pending reservation for a caller that was never admitted.
            pendingFills.removeValue(forKey: id)
            committedFills.formUnion(keys)
            return refused(.unsaved)
        }
        return Fill(admission: .admitted, added: added, id: id)
    }

    /// A fill succeeded, or its outcome is unknown: protection is permanent even after every
    /// overlapping attempt finishes. Unknown outcomes may have written credentials.
    public func completeFill(_ fill: Fill) {
        load()
        guard let id = fill.id, let keys = pendingFills.removeValue(forKey: id) else { return }
        committedFills.formUnion(keys)
    }

    /// The fill explicitly wrote nothing. Release only this attempt; any overlapping pending
    /// attempt, completed fill, or persisted mark keeps its origins protected.
    public func forgetFill(_ fill: Fill) {
        load()
        guard let id = fill.id, let keys = pendingFills.removeValue(forKey: id) else { return }
        let retained = pendingFills.values.reduce(into: committedFills) { $0.formUnion($1) }
        let removed = keys.subtracting(retained)
        guard !removed.isEmpty else { return }
        filled.subtract(removed)
        mirror()
        save(changed: removed)
    }

    /// One raw DevTools message in `profile`, checked without the actor so the relay keeps
    /// message order: false while the profile holds any filled login, or before the file was read.
    public nonisolated func rawMessageAllowed(profile: String?) -> Bool {
        let prefix = Self.key(profile: profile, origin: "")
        return mirrorState.withLock { mirror in
            guard let filled = mirror.filled else { return false }
            return !filled.contains { $0.hasPrefix(prefix) }
        }
    }

    /// A raw DevTools message reached `origin`: marked scripted at once (a fill there is refused
    /// from now on); true when it is new, so the caller persists it (``markScripted(profile:origins:)``).
    public nonisolated func noteRawSite(profile: String?, origin: String) -> Bool {
        let key = Self.key(profile: profile, origin: origin)
        return mirrorState.withLock { $0.rawScripted.insert(key).inserted }
    }

    /// Reads the file now (the app calls it at start, so the relay's mirror is ready).
    public func prepare() {
        load()
    }

    static func key(profile: String?, origin: String) -> String {
        "\(profile?.lowercased() ?? BrowserPageService.agentBrowserProfileID)|\(origin)"
    }

    private func holdsFill(_ profile: String?) -> Bool {
        let prefix = Self.key(profile: profile, origin: "")
        return filled.contains { $0.hasPrefix(prefix) }
    }

    private func insertScripted(_ keys: [String]) {
        let new = Set(keys).subtracting(scripted)
        guard !new.isEmpty else { return }
        scripted.formUnion(new)
        save(changed: new)
    }

    private func insertFilled(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        filled.formUnion(keys)
        mirror()
        save(changed: keys)
    }

    private func mirror() {
        let snapshot = filled
        mirrorState.withLock { $0.filled = snapshot }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        defer { mirror() }
        guard let file, FileManager.checked.fileExists(atPath: file.path(percentEncoded: false)) else { return }
        guard let data = try? Data(blockingContentsOf: file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else {
            // Fail closed: no fill until the file is repaired, and it is never overwritten.
            unreadable = true
            log.error("browser login guards: the guard file cannot be read; Secure Store fills are refused until it is repaired")
            return
        }
        scripted = Set(saved.scripted)
        filled = Set(saved.filled)
        committedFills = filled
    }

    /// Writes the marks; a failure keeps `changed` refused for fills until a save succeeds.
    private func save(changed: Set<String>) {
        guard let file, !unreadable else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        do {
            let data = try encoder.encode(Saved(scripted: scripted.sorted(), filled: filled.sorted()))
            try FileManager.checked.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.blockingWrite(to: file, options: .atomic)
            unsaved.removeAll()
        } catch {
            unsaved.formUnion(changed)
            // The error only: the marks name sites, never a login.
            log.error("browser login guards: saving failed: \(String(describing: error), privacy: .public)")
        }
    }
}
