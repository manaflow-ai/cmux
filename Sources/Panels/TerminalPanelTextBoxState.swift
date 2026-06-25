import Observation

@MainActor
@Observable
final class TerminalPanelTextBoxState {
    var pendingProviderLaunchAction: TextBoxSubmitAction?
}
