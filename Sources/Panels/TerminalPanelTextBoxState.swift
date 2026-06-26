import CmuxWorkspaces
import Observation

@MainActor
@Observable
final class TerminalPanelTextBoxState {
    var pendingProviderLaunchAction: TextBoxSubmitAction?
    private(set) var launchCommand: String?
    private var didObserveLaunchCommandRunning = false

    func recordLaunchCommand(_ rawCommand: String) {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        launchCommand = command
        didObserveLaunchCommandRunning = false
    }

    func clearLaunchCommand() {
        launchCommand = nil
        didObserveLaunchCommandRunning = false
    }

    func updateShellActivityState(_ state: PanelShellActivityState) {
        guard launchCommand != nil else { return }
        switch state {
        case .commandRunning:
            didObserveLaunchCommandRunning = true
        case .promptIdle where didObserveLaunchCommandRunning:
            clearLaunchCommand()
        case .promptIdle, .unknown:
            break
        }
    }
}
