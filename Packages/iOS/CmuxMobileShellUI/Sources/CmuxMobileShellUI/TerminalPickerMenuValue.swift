import CmuxMobileShellModel

/// Immutable state that determines the native terminal picker's presented menu.
struct TerminalPickerMenuValue: Equatable {
    let rows: [TerminalPickerMenuRow]
    let selectedID: MobileTerminalPreview.ID?
    let selectedName: String?
    let canCreateWorkspace: Bool
    let hasActiveBrowser: Bool
    let isChatMode: Bool
    let browserStreamRows: [BrowserStreamPickerRow]
    let supportsBrowserStream: Bool
    let activeBrowserStreamPanelID: String?

    init(
        liveTerminals: [MobileTerminalPreview],
        snapshotRows: [TerminalPickerMenuRow],
        selectedID: MobileTerminalPreview.ID?,
        canCreateWorkspace: Bool,
        hasActiveBrowser: Bool,
        isChatMode: Bool,
        browserStreamRows: [BrowserStreamPickerRow] = [],
        supportsBrowserStream: Bool = false,
        activeBrowserStreamPanelID: String? = nil
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
        self.browserStreamRows = browserStreamRows
        self.supportsBrowserStream = supportsBrowserStream
        self.activeBrowserStreamPanelID = activeBrowserStreamPanelID
    }
}
