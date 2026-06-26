import CmuxWorkspaces
import Observation

@MainActor
@Observable
final class TerminalPanelTextBoxState {
    var pendingProviderLaunchAction: TextBoxSubmitAction?
    private(set) var launchCommand: String?

    var activeLaunchCommand: String? {
        launchCommand
    }

    func recordLaunchCommand(_ rawCommand: String) {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        launchCommand = command
    }

    func clearLaunchCommand() {
        launchCommand = nil
    }

    func updateShellActivityState(_ state: PanelShellActivityState) {
        guard launchCommand != nil else { return }
        if state == .promptIdle {
            clearLaunchCommand()
        }
    }
}
