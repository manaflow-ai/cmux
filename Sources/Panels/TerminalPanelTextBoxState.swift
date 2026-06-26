import CmuxWorkspaces
import Observation

@MainActor
@Observable
final class TerminalPanelTextBoxState {
    var pendingProviderLaunchAction: TextBoxSubmitAction?
    private(set) var launchCommand: String?
    private var observedCommandRunningSinceLaunch = false

    var activeLaunchCommand: String? {
        observedCommandRunningSinceLaunch ? launchCommand : nil
    }

    func recordLaunchCommand(_ rawCommand: String) {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        launchCommand = command
        observedCommandRunningSinceLaunch = false
    }

    func clearLaunchCommand() {
        launchCommand = nil
        observedCommandRunningSinceLaunch = false
    }

    func updateShellActivityState(_ state: PanelShellActivityState) {
        guard launchCommand != nil else { return }
        if state == .commandRunning {
            observedCommandRunningSinceLaunch = true
            return
        }
        if state == .promptIdle && observedCommandRunningSinceLaunch {
            clearLaunchCommand()
        }
    }
}
