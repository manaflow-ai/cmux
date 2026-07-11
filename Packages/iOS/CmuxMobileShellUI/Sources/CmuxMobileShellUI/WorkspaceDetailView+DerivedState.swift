import CmuxMobileShellModel
import CmuxMobileWorkspace
import CoreGraphics

extension WorkspaceDetailView {
    var selectedTerminal: MobileTerminalPreview? {
        workspace.terminals.first { $0.id == store.selectedTerminalID } ?? workspace.terminals.first
    }

    var selectedTerminalID: String? {
        selectedTerminal?.id.rawValue
    }

    var selectedToolbarSubtitle: String? {
        guard let selectedTerminalID = store.selectedTerminalID else { return nil }
        return workspace.terminals.first { $0.id == selectedTerminalID }?.name
    }

    var terminalTopPadding: CGFloat { 4 }

    /// iOS renders the workspace title as a custom principal toolbar item. Keep
    /// the system title empty there so it does not draw a second centered title.
    var systemNavigationTitle: String {
        #if os(iOS)
        ""
        #else
        workspace.name
        #endif
    }
}
