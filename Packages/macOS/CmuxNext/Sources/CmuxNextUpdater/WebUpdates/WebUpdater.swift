public import CmuxNextWakeups
public import Foundation
import Observation

/// Web updates for cmux NEXT (plans/cmux-next/web-ota.md): the web bundles of every merge to
/// feat-cmux-next reach a NIGHTLY app minutes later, with no Mac build. The updater follows the
/// channel's signed pointer, downloads and checks the archive, keeps the tree
/// (``WebUpdateStore``) and hands it to ``onReady``; the app serves it from the next safe point
/// (``WebBundleOverlay`` in CmuxNextPages). An update is taken only when its signature, digests
/// and native interface (`abi`) check out and it is newer than both the web this app shipped with
/// and the last update taken; anything else keeps the web the app serves now.
@MainActor @Observable
public final class WebUpdater {
    /// `updates.web` in cmux.json.
    nonisolated public enum Channel: String, Sendable, CaseIterable {
        case off
        case nightly
        case everyMerge = "every-merge"
    }

    nonisolated public enum Phase: Equatable, Sendable {
        case idle
        case checking
        case downloading
        case failed(String)
    }

    /// A roll back asked for while a check runs: the check saves its own state when it ends and
    /// would undo it.
    nonisolated public struct Busy: Error, Sendable {}

    /// What the running app's own web bundles are.
    nonisolated public struct App: Sendable {
        /// `pages/web-abi.json` of the bundled pages.
        public var abi: Int
        /// When the bundled web was built, unix seconds: an update from an older commit than this
        /// is never newer than the bundle.
        public var webBuiltAt: Int

        public init(abi: Int, webBuiltAt: Int) {
            self.abi = abi
            self.webBuiltAt = webBuiltAt
        }

        /// The running app's bundled web: the `abi` of its `pages/web-abi.json` and, as its build
        /// time, the modification time of the app's `Info.plist`. NIGHTLY updates by Sparkle
        /// delta, which rewrites only the files whose bytes changed, so `web-abi.json` keeps the
        /// first install's time while every nightly rewrites the plist (its build number and
        /// commit). The plist's time is at or after the build, never before its commit.
        public static func bundled(pages: URL, infoPlist: URL) -> App? {
            guard let abi = WebUpdateTree.abi(inPages: pages),
                  let built = (try? infoPlist.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return nil }
            return App(abi: abi, webBuiltAt: Int(built.timeIntervalSince1970))
        }
    }

    /// Whether a bundle takes web updates: NIGHTLY (`com.cmuxterm.app.nightly[.<tag>]`) and the tip
    /// app (cmux NEXT DEV stamped with the tip feed, ``UpdateBuildIdentity/isTipBuild``), which both
    /// follow feat-cmux-next. Other Debug and DEV builds keep a developer's own web, and Release and
    /// RC builds the web they were built with.
    public nonisolated static func takesUpdates(_ identity: UpdateBuildIdentity) -> Bool {
        if identity.isTipBuild { return true }
        guard let bundle = identity.bundleIdentifier else { return false }
        return bundle == "com.cmuxterm.app.nightly" || bundle.hasPrefix("com.cmuxterm.app.nightly.")
    }

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias Download = @Sendable (URLRequest) async throws -> URL

    public internal(set) var channel = Channel.off
    public private(set) var phase = Phase.idle
    /// The update served now or from the next safe point; nil serves the bundled web.
    public private(set) var state = WebUpdateState()
    public private(set) var lastCheck: Date?
    /// Why the newest pointer was not taken (an app too old for it, an older commit), nil when it was.
    public private(set) var lastRefusal: WebUpdateRefusal?
    /// The update the launch check kept (nil: the bundled web), set with its tree.
    public private(set) var launchVersion: WebUpdatePointer?

    /// The app serves `tree`, the kept tree of `pointer` (both nil: the bundled web), from its next
    /// safe point.
    @ObservationIgnored public var onReady: (_ tree: URL?, _ pointer: WebUpdatePointer?) -> Void = { _, _ in }
    /// Whether downloads may use Low Data Mode and expensive links (`updates.meteredNetwork`).
    @ObservationIgnored public var allowsConstrained = false
    @ObservationIgnored public var allowsExpensive = true
    /// The folders the app serves now: the active one and each one a live document still loads its
    /// files from (a hidden or frozen page kept across a swap). None is pruned, even after a newer
    /// update or a roll back, until the safe point swapped it out and its last document went
    /// (``pruneUnused()``).
    @ObservationIgnored public var served: () -> [URL] = { [] }
    /// Whether cmux is in the front: checks come every ``interval`` there and every
    /// ``backgroundInterval`` behind other apps (``noteActivation(stale:)`` brings one in).
    @ObservationIgnored public var foreground = true
    /// Whether a cmux window shows: while none does, no check is booked (``noteShown(_:)``).
    @ObservationIgnored public private(set) var shown = true
    /// Whether the launch holds the network back: until ``startChecks()`` no check is booked or
    /// started by itself (a follow, an activation, a show); a check asked for by hand still runs.
    /// The app starts the checks once startup completes (Chrome's `AfterStartupTaskUtils`).
    @ObservationIgnored public private(set) var checksHeld: Bool

    let store: WebUpdateStore
    public let app: App
    let keySource: KeySource
    @ObservationIgnored var loadedKeys: WebUpdateKeys?  // ``trustedKeys()``
    let base: URL
    let fetch: Fetch
    let download: Download
    /// Between scheduled checks while cmux is in the front; the pointer is a small cached file
    /// read with its ETag (a 304 while unchanged), the archive is fetched only for a new update.
    let interval: Duration
    /// Between scheduled checks while cmux is behind other apps. A swap there runs once cmux has
    /// been behind for ``WebSwapGate/grace``, so this bounds how stale a backgrounded app gets:
    /// at 600 s a merge reached a NIGHTLY behind another app 10.8 minutes later (2026-10-25),
    /// past the five minutes Leo asked for. Each check is a small pointer read (a 304 while
    /// unchanged), so every two minutes stays quiet.
    let backgroundInterval: Duration
    public nonisolated static let defaultBackgroundInterval: Duration = .seconds(120)
    /// The app's Energy Saver policy: each wait is stretched by its `pollStretch`.
    let energy: EnergyPolicySource
    /// The next scheduled check: a `background` deadline (nobody waits on it) aligned to the app's
    /// hidden wakes (Blink's hidden-page wake-up throttling, page_scheduler_impl.h).
    @ObservationIgnored let nextCheck: MainDeadline
    /// Where a check runs: its network and disk parts off main, its state on main.
    @ObservationIgnored private let work: BackgroundWork
    /// The app's main-thread scheduler, where the launch check lands.
    @ObservationIgnored private let mainWork: MainWorkScheduler
    @ObservationIgnored private var etag: String?
    /// The launch check of the kept update; every check and channel change waits for it, so none
    /// sees the empty state before `state.json` is read.
    @ObservationIgnored private var launch: Task<URL?, Never>?
    /// What the app's launch read found on disk (``readKept(store:app:)``); nil reads it in ``launchTree()``.
    private let kept: Kept?
    /// The last state write queued (a check keeping its update, a roll back, a channel's return to
    /// the bundled web): each waits for the one before, so none saves over another.
    @ObservationIgnored private var writing: Task<Void, Never>?
    /// Whether `updates.web` was read yet (before it, `channel` is only the off default).
    @ObservationIgnored private var followed = false
    /// Counts ``follow(_:)`` calls, so a check that a channel change (even one changed back) ran
    /// during books the next read at once.
    @ObservationIgnored private var follows = 0

    public static let defaultBase = URL(string: "https://files.cmux.com/cmux-next-web/") ?? URL(fileURLWithPath: "/dev/null") // a test parses it

    /// - Parameters:
    ///   - deadlines: The app's deadline scheduler (the next check; the launch check lands on its `work`).
    ///   - checkNode: The app's visibility node (nil: flexible wakes only).
    ///   - work: The lanes a check starts on.
    ///   - kept: What the app's launch read found on disk (``readKept(store:app:)``); nil reads it in ``launchTree()``.
    ///   - checksHeld: Holds the network back until ``startChecks()`` (the app: until startup completes).
    public init(store: WebUpdateStore, app: App, keys: KeySource, base: URL = WebUpdater.defaultBase,
                interval: Duration = .seconds(60), backgroundInterval: Duration = WebUpdater.defaultBackgroundInterval,
                energy: EnergyPolicySource, deadlines: MainDeadlineScheduler, checkNode: VisibilityNode? = nil, work: BackgroundWork,
                kept: Kept? = nil, checksHeld: Bool = false,
                fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) },
                download: @escaping Download = WebUpdater.downloadToFile) {
        self.store = store
        self.app = app
        self.kept = kept
        self.checksHeld = checksHeld
        keySource = keys
        self.base = base
        self.interval = interval
        self.backgroundInterval = backgroundInterval
        self.energy = energy
        self.fetch = fetch
        self.download = download
        self.work = work
        mainWork = deadlines.work
        nextCheck = MainDeadline(owner: "web-updates.check", workClass: .background,
                                 alignment: checkNode.map(TimerAlignment.whenHidden) ?? .flexible, scheduler: deadlines)
    }

    /// Starts one ``check()`` on the app's lanes at `priority`: `bestEffort` for a scheduled one (its `background`
    /// deadline already waited for the launch), `userVisible` for one a person or a request asked for. Its state
    /// changes run on main.
    @discardableResult
    public func startCheck(_ priority: WorkPriority = .bestEffort) -> Task<Void, any Error> {
        work.task(priority) { [weak self] in
            guard let self else { return }
            await check()
        }
    }

    /// The launch check of the kept update, for ``WebBundleOverlay/load(_:)``: its folder when it
    /// still verifies, suits this app and came from the `updates.web` channel (not off), else nil
    /// (and the state forgets it). It runs once; later calls get its result.
    public func launchTree() async -> URL? {
        if let launch { return await launch.value }
        let store = store, app = app, kept = kept, channel: Channel? = followed ? channel : nil, mainWork = mainWork
        let land: @MainActor @Sendable (URL?, WebUpdateState) -> Void = { [weak self] tree, state in
            self?.state = state
            self?.launchVersion = tree == nil ? nil : state.active
        }
        // task-owner: the one launch check, off main, kept so later callers await the same result; the pages wait
        // for it, so its state lands as one visible task
        let task = Task { @concurrent () -> URL? in
            let found: Kept
            if let kept { found = kept } else { found = await Self.readKeptOffMain(store: store, app: app) }
            let (tree, state) = await Self.launchCheck(found, store: store, channel: channel)
            await mainWork.apply(.visible, owner: "WebUpdater.launch") { land(tree, state) }
            return tree
        }
        launch = task
        return await task.value
    }

    /// Follows `channel`: off stops the checks and returns to the bundled web; another channel
    /// returns to the bundled web unless that channel published the update served now.
    public func follow(_ channel: Channel) {
        guard !followed || channel != self.channel else { return }
        followed = true
        self.channel = channel
        follows += 1
        etag = nil
        nextCheck.cancel()
        // The launch check, then at most one state write, after the writes queued before it.
        _ = enqueue { [weak self] in
            _ = await self?.launchTree()
            guard let self, self.channel == channel, let active = state.active,
                  channel == .off || active.channel != channel.rawValue else { return }
            try await serve(nil, refusingActive: false)
        }
        guard channel != .off, !checksHeld else { return }
        nextCheck.schedule(after: .zero) { [weak self] in _ = self?.startCheck() }
    }

    /// Ends ``checksHeld``: the first check reads the channel's pointer at once while a window
    /// shows (else the next show books it, ``noteShown(_:)``).
    public func startChecks() {
        guard checksHeld else { return }
        checksHeld = false
        guard shown, channel != .off, phase != .checking, phase != .downloading, !nextCheck.isScheduled else { return }
        nextCheck.schedule(after: .zero) { [weak self] in _ = self?.startCheck() }
    }

    /// The app came to the front: checks again when the last check is older than `stale`, else
    /// books the next one at ``interval`` after the last (a check booked from the background
    /// waited ``backgroundInterval``).
    public func noteActivation(stale: TimeInterval = 60) {
        foreground = true
        guard !checksHeld, shown, channel != .off, phase != .checking, phase != .downloading else { return }
        // wall-clock: the wait since the shown lastCheck counts time asleep; the trace clock stops then.
        let since = Date().timeIntervalSince(lastCheck ?? .distantPast)
        guard since > stale else {
            nextCheck.schedule(after: Self.delay(after: since, interval: nextInterval)) { [weak self] in _ = self?.startCheck() }
            return
        }
        startCheck()
    }

    /// cmux went behind other apps: the check booked a minute out moves to ``backgroundInterval``
    /// after the last one.
    public func noteBackground() {
        foreground = false
        guard !checksHeld, channel != .off, phase != .checking, phase != .downloading, nextCheck.isScheduled else { return }
        // wall-clock: the wait since the shown lastCheck counts time asleep; the trace clock stops then.
        let since = Date().timeIntervalSince(lastCheck ?? .distantPast)
        nextCheck.schedule(after: Self.delay(after: since, interval: nextInterval)) { [weak self] in _ = self?.startCheck() }
    }

    /// The last cmux window went away: the booked check goes (a running one books none). A window
    /// showing again books the next one an interval after the last, at once when that has passed
    /// (Chromium runs a hidden page's due work once it shows).
    public func noteShown(_ shown: Bool) {
        guard shown != self.shown else { return }
        self.shown = shown
        guard shown else { return nextCheck.cancel() }
        guard !checksHeld, channel != .off, phase != .checking, phase != .downloading, !nextCheck.isScheduled else { return }
        // wall-clock: the wait since the shown lastCheck counts time asleep; the trace clock stops then.
        let since = Date().timeIntervalSince(lastCheck ?? .distantPast)
        nextCheck.schedule(after: Self.delay(after: since, interval: nextInterval)) { [weak self] in _ = self?.startCheck() }
    }

    /// The wait between two booked checks now: ``interval`` in the front, ``backgroundInterval``
    /// behind other apps, stretched by the Energy Saver.
    var nextInterval: Duration { (foreground ? interval : backgroundInterval) * energy.policy.pollStretch }

    /// The wait from now for a check `interval` after one `since` seconds ago (none when overdue).
    nonisolated static func delay(after since: TimeInterval, interval: Duration) -> Duration {
        .milliseconds(Int(max(0, WebSwapGate.seconds(interval) - since) * 1000))
    }

    /// Reads the channel's pointer and takes a new update.
    public func check() async {
        await writing?.value
        guard channel != .off, phase != .checking, phase != .downloading else { return }
        phase = .checking
        _ = await launchTree()
        let channel = channel, follows = follows
        lastCheck = Date()
        // Each check books the next one, so a check started by hand pushes the schedule back; a
        // channel changed during the check reads its own pointer at once.
        // While no window shows, only a channel change books one.
        defer {
            if !checksHeld, self.channel != .off, shown || self.follows != follows {
                nextCheck.schedule(after: self.follows == follows ? nextInterval : .zero) { [weak self] in _ = self?.startCheck() }
            }
        }
        do {
            guard let fresh = try await newPointer() else {
                phase = .idle
                return
            }
            let (pointer, tag) = fresh
            do {
                try take(pointer)
            } catch {
                // A lasting refusal: read the pointer again only when it changes.
                if self.channel == channel { etag = tag }
                throw error
            }
            phase = .downloading
            var request = URLRequest(url: pointer.archiveURL(base: base))
            request.allowsConstrainedNetworkAccess = allowsConstrained
            request.allowsExpensiveNetworkAccess = allowsExpensive
            let file: URL
            do {
                file = try await download(request)
            } catch {
                throw WebUpdateRefusal.transfer(error.localizedDescription)
            }
            defer { try? FileManager.default.removeItem(at: file) }
            let tree: URL
            do {
                tree = try await store.install(archive: file, pointer: pointer)
            } catch {
                // An archive that does not match its signed pointer stays wrong: not again until
                // the pointer changes.
                if let refusal = error as? WebUpdateRefusal, Self.isLasting(refusal), self.channel == channel { etag = tag }
                throw error
            }
            // Kept after the state writes queued during the download (a channel change).
            try await enqueue { [self] in
                guard self.channel == channel else {
                    // The channel changed during the download: drop the tree.
                    try? await Self.save(state, store: store, served: served())
                    phase = .idle
                    return
                }
                var next = state
                next.previous = state.active
                next.active = pointer
                next.floor = max(next.floor, pointer.committedAt)
                try await Self.save(next, store: store, served: served())
                guard self.channel == channel else {
                    // The channel changed during the save: put the state back (and drop the
                    // tree); the next check serves the right channel.
                    try? await Self.save(state, store: store, served: served())
                    phase = .idle
                    return
                }
                state = next
                etag = tag
                lastRefusal = nil
                phase = .idle
                onReady(tree, pointer)
            }.value
        } catch let refusal as WebUpdateRefusal {
            lastRefusal = refusal
            phase = refusal == .notNewer || Self.isAppTooOld(refusal) ? .idle : .failed(String(describing: refusal))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The channel's pointer when it changed since the last taken or refused one, verified, and
    /// its ETag (stored once the outcome lasts, so a failed download is tried again); nil when
    /// unchanged.
    func newPointer() async throws -> (WebUpdatePointer, String?)? {
        let channel = channel
        var request = URLRequest(url: base.appending(path: "ota/\(channel.rawValue).json"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await fetch(request)
        } catch {
            throw WebUpdateRefusal.transfer(error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        if http?.statusCode == 304 { return nil }
        // No pointer yet (the nightly channel before its first publish): nothing to take.
        if http?.statusCode == 404 { return nil }
        guard http?.statusCode == 200 else { throw WebUpdateRefusal.transfer("pointer status \(http?.statusCode ?? 0)") }
        let tag = http?.value(forHTTPHeaderField: "ETag")
        let keys = try await trustedKeys()
        do {
            return (try WebUpdatePointer.verified(data, keys: keys, channel: channel.rawValue), tag)
        } catch {
            if self.channel == channel { etag = tag }
            throw error
        }
    }

    /// Throws unless `pointer` suits this app and is newer than what it serves.
    func take(_ pointer: WebUpdatePointer) throws(WebUpdateRefusal) {
        guard pointer.abi == app.abi else { throw .abiMismatch(update: pointer.abi, app: app.abi) }
        guard pointer.key != state.active?.key, pointer.committedAt > max(state.floor, app.webBuiltAt) else { throw .notNewer }
    }

    /// Serves the update before the active one (the bundled web when there is none) from the next
    /// safe point. A rolled-back update is not taken again; the next newer one is. Refused
    /// (``Busy``) while a check runs; a check started meanwhile waits for it.
    public func rollBack() async throws {
        try await enqueue { [self] in
            guard state.active != nil else { return }
            guard phase != .checking, phase != .downloading else { throw Busy() }
            try await serve(state.previous, refusingActive: true)
        }.value
    }

    /// Runs `body` once the state write queued before it ends.
    private func enqueue(_ body: @escaping @MainActor () async throws -> Void) -> Task<Void, any Error> {
        let before = writing
        // task-owner: one state write; it ends by itself
        // main-hop-allow: the state writes' serial queue: each body is main-actor async (its file write @concurrent,
        // its state change on main) and starts only after the write before it; a channel change or a kept update
        let task = Task { @MainActor in
            await before?.value
            try await body()
        }
        // task-owner: the queue's handle on that write, off main (it only waits); it ends with it
        writing = Task { @concurrent in _ = try? await task.value }
        return task
    }

    /// Serves `pointer`'s kept update (nil: the bundled web) from the next safe point; with
    /// `refusingActive`, the active one is never taken again (a roll back).
    func serve(_ pointer: WebUpdatePointer?, refusingActive: Bool) async throws {
        var next = state
        next.active = pointer
        next.previous = nil
        if refusingActive, let active = state.active { next.floor = max(next.floor, active.committedAt) }
        try await Self.save(next, store: store, served: served())
        state = next
        onReady(pointer.map { store.tree(for: $0.key).root }, pointer)
    }

    @concurrent nonisolated static func save(_ state: WebUpdateState, store: WebUpdateStore, served: [URL] = []) async throws {
        try store.write(state)
        store.prune(keeping: state.keptKeys.union(served.map(\.lastPathComponent)))
    }

    /// Removes the kept trees nothing serves or may serve; the app calls it after a safe point.
    public func pruneUnused() async {
        // A check in flight may be unpacking into staging or keeping a tree it has not saved
        // yet; its own save prunes.
        guard phase != .checking, phase != .downloading else { return }
        let store = store, keys = state.keptKeys.union(served().map(\.lastPathComponent))
        await Self.prune(store, keeping: keys)
    }

    @concurrent nonisolated static func prune(_ store: WebUpdateStore, keeping keys: Set<String>) async {
        store.prune(keeping: keys)
    }

    /// Whether an install refusal is about the published archive itself (so trying again cannot
    /// help), not this machine (a full disk, an unreadable file).
    static func isLasting(_ refusal: WebUpdateRefusal) -> Bool {
        guard case .integrity(let what) = refusal else { return false }
        return ["archive digest", "tree digest", "tree abi", "archive too large", "link ", "special file "].contains { what.hasPrefix($0) }
    }

    static func isAppTooOld(_ refusal: WebUpdateRefusal) -> Bool {
        if case .abiMismatch = refusal { return true }
        return false
    }

    /// Downloads to a temporary file the caller removes.
    @concurrent public nonisolated static func downloadToFile(_ request: URLRequest) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw WebUpdateRefusal.transfer("archive status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let kept = FileManager.default.temporaryDirectory.appending(path: "cmux-web-update-\(UUID().uuidString).tar.gz")
        try FileManager.default.moveItem(at: file, to: kept)
        return kept
    }
}
