import CMUXAgentLaunch

/// Main-actor bridge from the monitor service into the app composition root.
@MainActor
final class CodexTranscriptMonitorEventTarget {
    weak var controller: TerminalController?

    func resolveOwnership(
        _ targets: [String: CodexTranscriptMonitorTarget]
    ) -> [String: CodexTranscriptMonitorOwnership] {
        guard let controller else {
            return targets.mapValues { _ in .unknown }
        }
        return targets.mapValues { controller.codexTranscriptMonitorOwnership(for: $0) }
    }

    func publish(
        request: CodexTranscriptMonitorRequest,
        target: CodexTranscriptMonitorTarget,
        update: CodexTranscriptMonitorUpdate
    ) {
        guard let controller else { return }
        let liveTarget: CodexTranscriptMonitorTarget
        switch controller.codexTranscriptMonitorOwnership(for: target) {
        case .alive(let resolvedTarget):
            liveTarget = resolvedTarget
        case .gone:
            return
        case .unknown:
            liveTarget = target
        }
        controller.publishCodexTranscriptMonitorUpdate(
            update,
            request: request,
            target: liveTarget
        )
    }
}
