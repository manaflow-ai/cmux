@MainActor
protocol TerminalPanelCreating: AnyObject {
    func makeTerminalPanel(_ request: TerminalPanelCreationRequest) -> TerminalPanel
}
