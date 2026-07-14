import CmuxMobileSupport
import SwiftUI

extension WorkspaceDetailView {
    var newWorkspaceToolbarButton: some View {
        Button(action: createWorkspaceFromToolbar) {
            Label(
                L10n.string("mobile.workspace.new", defaultValue: "New Workspace"),
                systemImage: "plus.square.on.square"
            )
            .labelStyle(.iconOnly)
        }
        .foregroundStyle(TerminalPalette.foreground)
        .disabled(!canCreateWorkspace)
        .accessibilityIdentifier("MobileTerminalNewWorkspaceButton")
    }

    var terminalPickerToolbarButton: some View {
        let selection = terminalPickerLiveRows.resolvedTerminalPickerSelection(
            selectedID: store.selectedTerminalID
        )
        return Button {
            dismissTerminalKeyboardForChrome()
            isTerminalHierarchyPresented = true
        } label: {
            Label(
                selection?.name ?? L10n.string(
                    "mobile.terminal.select",
                    defaultValue: "Terminal"
                ),
                systemImage: "rectangle.stack"
            )
            .labelStyle(.iconOnly)
        }
        .foregroundStyle(TerminalPalette.foreground)
        .accessibilityLabel(
            L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals")
        )
        .accessibilityHint(
            L10n.string(
                "mobile.terminal.hierarchy.hint",
                defaultValue: "Shows terminals grouped by pane"
            )
        )
        .accessibilityIdentifier("MobileTerminalHierarchyButton")
        .accessibilityValue(selection?.name ?? "")
    }

    var newTerminalToolbarButton: some View {
        Button(action: createTerminalFromToolbar) {
            Label(
                L10n.string("mobile.terminal.new", defaultValue: "New Terminal"),
                systemImage: "plus"
            )
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
        }
        .foregroundStyle(TerminalPalette.foreground)
        .disabled(!canCreateTerminalFromHierarchy)
        .accessibilityHint(
            L10n.string(
                "mobile.terminal.hierarchy.newHint",
                defaultValue: "Creates and selects a terminal in the focused pane"
            )
        )
        .accessibilityIdentifier("MobileTerminalNewTerminalButton")
    }

    func createWorkspaceFromToolbar() {
        guard canCreateWorkspace else { return }
        dismissTerminalKeyboardForChrome()
        createWorkspace()
    }

    func createTerminalFromToolbar() {
        guard canCreateTerminalFromHierarchy else { return }
        dismissTerminalKeyboardForChrome()
        // Creating a terminal from the shared chrome must surface it. If a
        // browser pane is up, close it so the new terminal becomes visible.
        browserStore.closeBrowser(for: workspace.id.rawValue)
        createTerminal()
    }

    private var canCreateTerminalFromHierarchy: Bool {
        connectionStatus == .connected
            && store.terminalReorderGate.canMutate(workspaceID: workspace.id)
    }
}
