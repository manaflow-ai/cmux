import CMUXAgentLaunch
import CmuxTerminal

@MainActor
final class AgentTerminalPanelInputWriter: AgentTerminalInputWriting {
    private let panel: TerminalPanel

    init(panel: TerminalPanel) {
        self.panel = panel
    }

    func sendNamedKey(_ keyName: String) -> AgentLaunchExecutionResult {
        switch panel.sendNamedKeyResult(keyName) {
        case .sent:
            return .accepted
        case .queued:
            return .queued
        case .inputQueueFull:
            return .failed("input_queue_full")
        case .processExited:
            return .failed("process_exited")
        case .unknownKey, .surfaceUnavailable:
            return .failed("binding_lost")
        }
    }

    func sendText(_ text: String) -> AgentLaunchExecutionResult {
        panel.sendText(text) ? .accepted : .failed("binding_lost")
    }
}
