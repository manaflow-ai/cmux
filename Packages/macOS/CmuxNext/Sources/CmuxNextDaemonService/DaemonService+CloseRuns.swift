public import CmuxNextDaemon

/// Running a pane's close commands (`PaneController.close`).
extension DaemonService {
    public typealias CloseRun = (String, DaemonCommandBody)

    /// One `close-tabs` command for several surfaces when the daemon has
    /// `batch-close-v1`, else `commands` (one per tab).
    public func closeRuns(surfaces: [SurfaceID], commands: [CloseRun]) -> [CloseRun] {
        guard surfaces.count > 1, supports(DaemonCapability.batchClose.rawValue) else { return commands }
        let close: DaemonCommandBody = { @Sendable [surfaces] connection in _ = try await connection.closeTabs(surfaces, endTerminals: false) }
        return [(Self.batchCloseLabel(commands), preparingClose(of: surfaces, then: close))]
    }

    /// Keep each distinct kind/entrypoint when one command replaces several.
    /// Repeated tabs of the same kind do not grow the diagnostic line.
    static func batchCloseLabel(_ commands: [CloseRun]) -> String {
        let labels = Set(commands.map { $0.0 }).sorted().joined(separator: "; ")
        return "close-tabs [\(labels)]"
    }

    /// Runs `runs` in order (``runReportingTimeout(_:_:)`` each): whether
    /// any failed or missed its deadline, and the failures' error codes.
    public func runReportingOutcomes(_ runs: [CloseRun]) async
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
