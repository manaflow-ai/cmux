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

    /// The fetch ``WebUpdater/casFetch`` runs while `updates.webCas` is on; nil without the
    /// bundled CLI.
    func casFetcher() -> WebUpdater.CasFetch? {
        guard let cli = bundledCLI else { return nil }
        return { request in
            guard await Self.linkAllows(request) else { return .failure(.init("metered link")) }
            guard let url = await cli.resolve() else { return .failure(.init("no cmux CLI")) }
            guard let ran = await BundledCLIRun.run(url, Self.casWords(request), timeout: Self.casTimeout) else {
                return .failure(.init("cmux app web-cas fetch did not finish"))
            }
            guard ran.status == 0 else {
                return .failure(.init(BundledCLIRun.lastLine(ran.stderr) ?? "cmux app web-cas fetch exited \(ran.status)"))
            }
            guard let report = WebUpdater.CasReport.parse(ran.stdout) else { return .failure(.init("no report")) }
            return .success(report)
        }
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
        for await path in NWPathMonitor() {
            return path.status == .satisfied && (request.allowsConstrained || !path.isConstrained)
                && (request.allowsExpensive || !path.isExpensive)
        }
        return false
        #else
        return true
        #endif
    }
}
