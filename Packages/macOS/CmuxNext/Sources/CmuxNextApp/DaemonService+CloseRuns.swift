import CmuxNextDaemon

/// Running a pane's close commands (`PaneController.close`).
extension DaemonService {
    typealias CloseRun = (String, @Sendable (DaemonConnection) async throws -> Void)

    /// One `close-tabs` command for several surfaces when the daemon has
    /// `batch-close-v1`, else `commands` (one per tab).
    func closeRuns(surfaces: [SurfaceID], commands: [CloseRun]) -> [CloseRun] {
        guard surfaces.count > 1, supports(DaemonCapabilities.shared.batchClose) else { return commands }
        return [("close-tabs", { @Sendable [surfaces] connection in _ = try await connection.closeTabs(surfaces, endTerminals: false) })]
    }

    /// Runs `runs` in order (``runReportingTimeout(_:_:)`` each): whether
    /// any failed or missed its deadline, and the failures' error codes.
    func runReportingOutcomes(_ runs: [CloseRun]) async
        -> (failed: Bool, unknown: Bool, codes: [String]) {
        var outcome = (failed: false, unknown: false, codes: [String]())
        for (label, body) in runs {
            switch await runReportingTimeout(label, body) {
            case .succeeded: break
            case .failed(let code):
                outcome.failed = true
                outcome.codes += code.map { [$0] } ?? []
            case .unknown: outcome.unknown = true
            }
        }
        return outcome
    }
}
