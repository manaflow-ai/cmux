import CmuxNextDaemon
import CmuxNextUpdater
import Foundation
#if canImport(Network)
import Network
#endif

// Web updates by `cas/1` (RFD 0166, cmuxterm-hq docs/rfd/0166-own-cdn.md), behind
// `updates.webCas` (off by default): a new update's tree is fetched with the app's bundled
// `cmux app web-cas fetch`, which reads only the chunks the kept trees lack, by Range GETs on the
// pack the signed pointer names, and checks every id (cmux-tui/crates/cmux-cas). The updater
// then checks the tree against the pointer's digest like an unpacked archive; any miss takes the
// archive in the same check (``WebUpdater/casFetch``).

extension WebUpdates {
    /// One fetch is one manifest, one index and the ranges of a ~17 MB pack; each request has its
    /// own 120 s bound in the CLI.
    nonisolated static let casTimeout: Duration = .seconds(300)

    /// The fetch ``WebUpdater/casFetch`` runs while `updates.webCas` is on. Without the bundled
    /// CLI every fetch is a miss that says so (`last_fetch.cas_miss`), never a silent archive.
    func casFetcher() -> WebUpdater.CasFetch {
        guard let cli = bundledCLI else { return { _ in .failure(.init("no bundled cmux CLI")) } }
        return { request in
            guard await Self.linkAllows(request) else { return .failure(.init("metered link")) }
            guard let url = await cli.resolve() else { return .failure(.init("no cmux CLI")) }
            let ended = await Self.runWhileLinkAllows(request) {
                await BundledCLIRun.run(url, Self.casWords(request), timeout: Self.casTimeout)
            }
            guard case .ran(let finished) = ended else { return .failure(.init("link turned metered during the fetch")) }
            guard let ran = finished else { return .failure(.init("cmux app web-cas fetch did not finish")) }
            guard ran.status == 0 else {
                return .failure(.init(BundledCLIRun.lastLine(ran.stderr) ?? "cmux app web-cas fetch exited \(ran.status)"))
            }
            guard let report = WebUpdater.CasReport.parse(ran.stdout) else { return .failure(.init("no report")) }
            return .success(report)
        }
    }

    /// How a fetch run under ``runWhileLinkAllows(_:lost:_:)`` ended.
    nonisolated enum CasRunEnd<Value: Sendable>: Sendable { case ran(Value), linkLost }

    /// Runs `body` while the link keeps allowing `request`: a link that turns constrained or
    /// expensive (or drops) mid-fetch cancels it, which kills the CLI child (ProcessRunner), the
    /// same rule the archive's URLSession task keeps for its whole download. `lost` returns when
    /// the link stops allowing it (``linkLost(_:)``; tests pass their own).
    nonisolated static func runWhileLinkAllows<Value: Sendable>(_ request: WebUpdater.CasRequest,
                                                                lost: @escaping @Sendable (WebUpdater.CasRequest) async -> Void = linkLost,
                                                                _ body: @escaping @Sendable () async -> Value) async -> CasRunEnd<Value> {
        await withTaskGroup(of: CasRunEnd<Value>.self) { group in
            group.addTask { .ran(await body()) }
            group.addTask { await lost(request); return .linkLost }
            let first = await group.next() ?? .linkLost
            group.cancelAll()
            return first
        }
    }

    /// Whether `path` allows a fetch with `request`'s metered-network rules.
    #if canImport(Network)
    nonisolated static func allows(_ path: NWPath, _ request: WebUpdater.CasRequest) -> Bool {
        path.status == .satisfied && (request.allowsConstrained || !path.isConstrained)
            && (request.allowsExpensive || !path.isExpensive)
    }
    #endif

    /// Returns once the link stops allowing `request`, or when cancelled.
    nonisolated static func linkLost(_ request: WebUpdater.CasRequest) async {
        #if canImport(Network)
        // The monitor's own sequence: a cancel ends it (as PathMonitorChromiumRuntimeNetwork's wait).
        for await path in NWPathMonitor() where !allows(path, request) { return }
        #else
        for await _ in AsyncStream<Never>(Never.self, { _ in }) {}
        #endif
    }

    /// The CLI's words for `request` (cmux-tui `cli/app/web_cas.rs`).
    nonisolated static func casWords(_ request: WebUpdater.CasRequest) -> [String] {
        var words = ["app", "web-cas", "fetch", "--manifest", request.manifest, "--pack", request.pack,
                     "--store", request.chunks.path, "--out", request.out.path, "--base", request.base.absoluteString]
        for tree in request.have { words += ["--have", tree.path] }
        return words
    }

    /// The archive download honours Low Data Mode and expensive links through URLSession; the CLI
    /// cannot, so the link is read here first, with the same rules.
    nonisolated static func linkAllows(_ request: WebUpdater.CasRequest) async -> Bool {
        #if canImport(Network)
        for await path in NWPathMonitor() { return allows(path, request) }
        return false
        #else
        return true
        #endif
    }
}
