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
            guard let url = await cli.resolve() else { return .failure(.init("no cmux CLI")) }
            let ended = await Self.runWhileLinkAllows(request) {
                await BundledCLIRun.run(url, Self.casWords(request), timeout: Self.casTimeout)
            }
            let finished: ProcessResult?
            switch ended {
            case .ran(let result): finished = result
            case .metered: return .failure(.init("metered link"))
            case .linkLost: return .failure(.init("link turned metered during the fetch"))
            }
            guard let ran = finished else { return .failure(.init("cmux app web-cas fetch did not finish")) }
            guard ran.status == 0 else {
                return .failure(.init(BundledCLIRun.lastLine(ran.stderr) ?? "cmux app web-cas fetch exited \(ran.status)"))
            }
            guard let report = WebUpdater.CasReport.parse(ran.stdout) else { return .failure(.init("no report")) }
            return .success(report)
        }
    }

    /// How a fetch run under ``runWhileLinkAllows(_:watch:_:)`` ended: it ran, the link never
    /// allowed it (it did not start), or the link stopped allowing it midway (it was cancelled).
    nonisolated enum CasRunEnd<Value: Sendable>: Sendable { case ran(Value), metered, linkLost }

    /// Runs `body` while the link allows `request`, with one monitor from start to end: `body`
    /// starts only once that monitor's first path allows it, so the link cannot turn between a
    /// check and the start; a later path that does not allow it (Low Data Mode, an expensive link
    /// against `updates.meteredNetwork`, or none) cancels `body`, which kills the CLI child
    /// (ProcessRunner). The archive's URLSession task keeps the same rule for its whole download.
    /// `watch` hands each path's answer to its callback until that returns false
    /// (``watchLink(_:_:)``; tests pass their own).
    nonisolated static func runWhileLinkAllows<Value: Sendable>(
        _ request: WebUpdater.CasRequest,
        watch: @escaping @Sendable (WebUpdater.CasRequest, (Bool) -> Bool) async -> Void = watchLink,
        _ body: @escaping @Sendable () async -> Value
    ) async -> CasRunEnd<Value> {
        let (gate, open) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        return await withTaskGroup(of: CasRunEnd<Value>.self) { group in
            group.addTask {
                for await _ in gate { return .ran(await body()) }
                return .linkLost
            }
            group.addTask {
                var started = false
                await watch(request) { ok in
                    guard ok else { return false }
                    if !started { started = true; open.yield(); open.finish() }
                    return true
                }
                return started ? .linkLost : .metered
            }
            let first = await group.next() ?? .linkLost
            open.finish()
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

    /// Hands each path's answer for `request` from one `NWPathMonitor` to `each` until it returns
    /// false or the caller is cancelled. The monitor's own sequence: a cancel ends it (as
    /// PathMonitorChromiumRuntimeNetwork's wait).
    nonisolated static func watchLink(_ request: WebUpdater.CasRequest, _ each: (Bool) -> Bool) async {
        #if canImport(Network)
        for await path in NWPathMonitor() where !each(allows(path, request)) { return }
        #else
        guard each(true) else { return }
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
}
