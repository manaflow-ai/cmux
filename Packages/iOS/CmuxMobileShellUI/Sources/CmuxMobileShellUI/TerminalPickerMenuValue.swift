import CmuxMobileShellModel

/// Immutable state that determines the native terminal picker's presented menu.
struct TerminalPickerMenuValue: Equatable {
    let rows: [TerminalPickerMenuRow]
    let selectedID: MobileTerminalPreview.ID?
    let selectedName: String?
    let canCreateWorkspace: Bool
    let hasActiveBrowser: Bool
    let isChatMode: Bool

    init(
        liveTerminals: [MobileTerminalPreview],
        snapshotRows: [TerminalPickerMenuRow],
        selectedID: MobileTerminalPreview.ID?,
        canCreateWorkspace: Bool,
        hasActiveBrowser: Bool,
        isChatMode: Bool
    ) {
        rows = snapshotRows.isEmpty
            ? liveTerminals.map(TerminalPickerMenuRow.init)
            : snapshotRows
        let selection = rows.resolvedTerminalPickerSelection(selectedID: selectedID)
        self.selectedID = selection?.id
        selectedName = selection?.name
        self.canCreateWorkspace = canCreateWorkspace
        self.hasActiveBrowser = hasActiveBrowser
        self.isChatMode = isChatMode
    }
}
