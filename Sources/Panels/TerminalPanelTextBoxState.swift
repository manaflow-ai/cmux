import CmuxWorkspaces
import Foundation
import Observation

@MainActor
@Observable
final class TerminalPanelTextBoxState {
    var selectedSubmitActionID: String?
    var pendingProviderLaunchAction: TextBoxSubmitAction?
    var pendingProviderLaunchStartedAt: Date?
    private(set) var launchCommand: String?
    private var observedCommandRunningSinceLaunch = false

    init(defaults: UserDefaults = .standard) {
        selectedSubmitActionID = TerminalTextBoxInputSettings.rememberedSubmitActionIDValue(defaults: defaults)
    }

    var pendingLaunchCommand: String? {
        observedCommandRunningSinceLaunch ? nil : launchCommand
    }

    func selectSubmitAction(_ id: String, defaults: UserDefaults = .standard) {
        guard TerminalTextBoxInputSettings.rememberSubmitActionID(id, defaults: defaults) else { return }
        selectedSubmitActionID = id
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
            guard !observedCommandRunningSinceLaunch else { return }
            observedCommandRunningSinceLaunch = true
            return
        }
        if state == .promptIdle, observedCommandRunningSinceLaunch {
            clearLaunchCommand()
        }
    }
}
