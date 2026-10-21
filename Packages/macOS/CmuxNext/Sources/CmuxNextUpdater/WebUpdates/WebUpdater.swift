import CmuxNextWakeups
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
    public enum Channel: String, Sendable, CaseIterable {
        case off
        case nightly
        case everyMerge = "every-merge"
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case checking
        case downloading
        case failed(String)
    }

    /// What the running app's own web bundles are.
    public struct App: Sendable {
        /// `pages/web-abi.json` of the bundled pages.
        public var abi: Int
        /// When the bundled web was built (that file's modification time), unix seconds: an update
        /// from an older commit than this is never newer than the bundle.
        public var webBuiltAt: Int

        public init(abi: Int, webBuiltAt: Int) {
            self.abi = abi
            self.webBuiltAt = webBuiltAt
        }
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

    /// The app serves `tree` (nil: the bundled web) from its next safe point.
    @ObservationIgnored public var onReady: (URL?) -> Void = { _ in }
    /// Whether downloads may use Low Data Mode and expensive links (`updates.meteredNetwork`).
    @ObservationIgnored public var allowsConstrained = false
    @ObservationIgnored public var allowsExpensive = true

    let store: WebUpdateStore
    public let app: App
    let keys: WebUpdateKeys
    let base: URL
    let fetch: Fetch
    let download: Download
    /// Between scheduled checks; the pointer is a small cached file, the archive is fetched only
    /// for a new update.
    let interval: Duration
    /// The next scheduled check.
    @ObservationIgnored private let nextCheck: DemandTimer
    @ObservationIgnored private var etag: String?

    public static let defaultBase = URL(string: "https://files.cmux.com/cmux-next-web/") ?? URL(fileURLWithPath: "/dev/null") // a test parses it

    public init(store: WebUpdateStore, app: App, keys: WebUpdateKeys = .bundled, base: URL = WebUpdater.defaultBase,
                interval: Duration = .seconds(600), clock: any Clock<Duration> = ContinuousClock(),
                fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) },
                download: @escaping Download = WebUpdater.downloadToFile) {
        self.store = store
        self.app = app
        self.keys = keys
        self.base = base
        self.interval = interval
        self.fetch = fetch
        self.download = download
        nextCheck = DemandTimer(owner: "web-updates.check", clock: clock)
    }

    /// The launch check of the kept update, for ``WebBundleOverlay/load(_:)``: its folder when it
    /// still verifies and suits this app, else nil (and the state forgets it).
    public nonisolated func launchTree() async -> URL? {
        let store = store, app = app
        let (tree, state) = await Self.launchCheck(store: store, app: app)
        await MainActor.run { self.state = state }
        return tree
    }

    @concurrent nonisolated static func launchCheck(store: WebUpdateStore, app: App) async -> (URL?, WebUpdateState) {
        var state = store.readState()
        guard let active = state.active else { return (nil, state) }
        if active.abi == app.abi, active.committedAt > app.webBuiltAt, let tree = store.verifiedTree(active) {
            return (tree, state)
        }
        // A newer app shipped newer web, or the tree changed on disk: serve the bundle.
        state.active = nil
        state.previous = nil
        try? store.write(state)
        store.prune(keeping: [])
        return (nil, state)
    }

    /// Follows `channel`: off stops the checks and returns to the bundled web.
    public func follow(_ channel: Channel) {
        guard channel != self.channel else { return }
        self.channel = channel
        etag = nil
        nextCheck.cancel()
        guard channel != .off else {
            // task-owner: one state write; it ends by itself
            if state.active != nil { Task { try? await serve(nil, refusingActive: false) } }
            return
        }
        nextCheck.schedule(after: .zero) { @MainActor [weak self] in await self?.check() }
    }

    /// The app came to the front: checks again when the last check is older than `stale`.
    public func noteActivation(stale: TimeInterval = 120) {
        guard channel != .off, phase != .checking, phase != .downloading,
              Date().timeIntervalSince(lastCheck ?? .distantPast) > stale else { return }
        // task-owner: one check; it ends by itself
        Task { await check() }
    }

    /// Reads the channel's pointer and takes a new update.
    public func check() async {
        guard channel != .off, phase != .checking, phase != .downloading else { return }
        phase = .checking
        lastCheck = Date()
        // Each check books the next one, so a check started by hand pushes the schedule back.
        defer {
            if channel != .off { nextCheck.schedule(after: interval) { @MainActor [weak self] in await self?.check() } }
        }
        do {
            guard let pointer = try await newPointer() else {
                phase = .idle
                return
            }
            try take(pointer)
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
            let tree = try await store.install(archive: file, pointer: pointer)
            var next = state
            next.previous = state.active
            next.active = pointer
            next.floor = max(next.floor, pointer.committedAt)
            try await Self.save(next, store: store)
            state = next
            lastRefusal = nil
            phase = .idle
            onReady(tree)
        } catch let refusal as WebUpdateRefusal {
            lastRefusal = refusal
            phase = refusal == .notNewer || Self.isAppTooOld(refusal) ? .idle : .failed(String(describing: refusal))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The channel's pointer when it changed since the last read, verified; nil when unchanged.
    func newPointer() async throws -> WebUpdatePointer? {
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
        let pointer = try WebUpdatePointer.verified(data, keys: keys, channel: channel.rawValue)
        etag = http?.value(forHTTPHeaderField: "ETag")
        return pointer
    }

    /// Throws unless `pointer` suits this app and is newer than what it serves.
    func take(_ pointer: WebUpdatePointer) throws(WebUpdateRefusal) {
        guard pointer.abi == app.abi else { throw .abiMismatch(update: pointer.abi, app: app.abi) }
        guard pointer.key != state.active?.key, pointer.committedAt > max(state.floor, app.webBuiltAt) else { throw .notNewer }
    }

    /// Serves the update before the active one (the bundled web when there is none) from the next
    /// safe point. A rolled-back update is not taken again; the next newer one is.
    public func rollBack() async throws {
        guard state.active != nil else { return }
        try await serve(state.previous, refusingActive: true)
    }

    /// Serves `pointer`'s kept update (nil: the bundled web) from the next safe point; with
    /// `refusingActive`, the active one is never taken again (a roll back).
    func serve(_ pointer: WebUpdatePointer?, refusingActive: Bool) async throws {
        var next = state
        next.active = pointer
        next.previous = nil
        if refusingActive, let active = state.active { next.floor = max(next.floor, active.committedAt) }
        try await Self.save(next, store: store)
        state = next
        onReady(pointer.map { store.tree(for: $0.key).root })
    }

    @concurrent nonisolated static func save(_ state: WebUpdateState, store: WebUpdateStore) async throws {
        try store.write(state)
        store.prune(keeping: state.keptKeys)
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
