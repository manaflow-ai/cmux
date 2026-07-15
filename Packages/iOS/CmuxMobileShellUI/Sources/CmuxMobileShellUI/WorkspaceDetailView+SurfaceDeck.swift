import CmuxMobileShellModel
import SwiftUI

extension WorkspaceDetailView {
    var surfaceDeckValue: WorkspaceSurfaceDeckValue {
        WorkspaceSurfaceDeckValue(
            workspace: workspace,
            selectedTerminalID: store.selectedTerminalID,
            paneSelections: phonePaneSelections
        )
    }

    var workspaceSurfaceDeck: some View {
        WorkspaceSurfaceDeck(
            value: surfaceDeckValue,
            terminalTheme: store.activeTerminalTheme,
            actions: WorkspaceSurfaceDeckActions(
                selectTerminal: selectTerminalFromDeck,
                createTerminal: createTerminalFromDeck,
                showOverview: {
                    dismissTerminalKeyboardForChrome()
                    isPaneOverviewPresented = true
                }
            )
        )
    }

    func rememberSelectedTerminalInPane() {
        guard let terminalID = store.selectedTerminalID,
              let pane = surfaceDeckValue.panes.first(where: { pane in
                  pane.terminals.contains(where: { $0.id == terminalID })
              }) else {
            return
        }
        phonePaneSelections[pane.id] = terminalID
    }
}
