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
///   ever had a raw DevTools relay (it reaches every site that tab visits) or that a page opened.
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
        /// A page opened the tab: its opener's script could reach in.
        case openedByPage = "opened_by_page"
        case unreadable = "guard_unreadable"
        case unsaved = "guard_unsaved"
    }

    private struct Saved: Codable {
        var scripted: [String]
        var filled: [String]
    }

    /// The filled keys, readable without the actor for the raw DevTools relay's per-message check
    /// (``rawMessageAllowed(profile:origin:)``). Nil until the file was read.
    private let filledMirror = Mutex<Set<String>?>(nil)

    private let file: URL?
    private var scripted: Set<String> = []
    private var filled: Set<String> = []
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
    /// empty: an opaque page, no site). False when one of them holds a filled login, or when the
    /// origin is unknown and this profile holds any; else each is marked scripted.
    public func beginScript(profile: String?, origins: [String]?) -> Bool {
        load()
        guard let origins else { return !holdsFill(profile) }
        let keys = origins.map { Self.key(profile: profile, origin: $0) }
        if keys.contains(where: filled.contains) { return false }
        insert(keys, scripted: true)
        return true
    }

    /// Marks `origins` scripted after agent code ran (it may have moved to another site).
    public func markScripted(profile: String?, origins: [String]?) {
        load()
        insert((origins ?? []).map { Self.key(profile: profile, origin: $0) }, scripted: true)
    }

    /// A raw DevTools relay is about to attach to `tab` showing `origins` (nil: unknown). False
    /// when one of them holds a filled login (or, unknown, the profile holds any); else the
    /// origins are marked scripted and the tab never gets a fill.
    public func beginRawDevTools(tab: String, profile: String?, origins: [String]?) -> Bool {
        guard beginScript(profile: profile, origins: origins) else { return false }
        rawTabs.insert(tab)
        return true
    }

    /// A page opened `tab` (a popup): it never gets a fill.
    public func markOpenedByPage(tab: String) {
        openedTabs.insert(tab)
    }

    /// A login is about to be filled into `tab`, a page of `origins`. Refused when agent code ran
    /// on one of them, the tab had a raw DevTools relay or a page opened it, or the guard file
    /// cannot be read or saved; else each origin is marked filled.
    public func beginFill(tab: String, profile: String?, origins: [String]) -> FillAdmission {
        load()
        if unreadable { return .unreadable }
        if openedTabs.contains(tab) { return .openedByPage }
        let keys = origins.map { Self.key(profile: profile, origin: $0) }
        if rawTabs.contains(tab) || keys.contains(where: scripted.contains) { return .scripted }
        if keys.contains(where: unsaved.contains) { return .unsaved }
        insert(keys, scripted: false)
        return keys.contains(where: unsaved.contains) ? .unsaved : .admitted
    }

    /// The fill set nothing on `origins` (no login field, or the page moved first).
    public func forgetFill(profile: String?, origins: [String]) {
        load()
        let keys = Set(origins.map { Self.key(profile: profile, origin: $0) })
        guard !filled.isDisjoint(with: keys) else { return }
        filled.subtract(keys)
        mirror()
        save(changed: keys)
    }

    /// One raw DevTools message on a tab now at `origin` (nil: unknown), checked without the
    /// actor so the relay keeps message order: false while the origin holds a filled login (or,
    /// unknown or before the file was read, while the profile holds any). The caller marks the
    /// origin scripted (``markScripted(profile:origins:)``).
    public nonisolated func rawMessageAllowed(profile: String?, origin: String?) -> Bool {
        filledMirror.withLock { filled in
            guard let filled else { return false }
            guard let origin else {
                let prefix = Self.key(profile: profile, origin: "")
                return !filled.contains { $0.hasPrefix(prefix) }
            }
            return !filled.contains(Self.key(profile: profile, origin: origin))
        }
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

    private func insert(_ keys: [String], scripted toScripted: Bool) {
        let new = Set(keys).subtracting(toScripted ? scripted : filled)
        guard !new.isEmpty else { return }
        if toScripted { scripted.formUnion(new) } else { filled.formUnion(new) }
        if !toScripted { mirror() }
        save(changed: new)
    }

    private func mirror() {
        let snapshot = filled
        filledMirror.withLock { $0 = snapshot }
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
