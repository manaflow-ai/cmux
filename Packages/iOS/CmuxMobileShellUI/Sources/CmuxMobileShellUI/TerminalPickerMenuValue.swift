import CmuxMobileShellModel

struct TerminalPickerMenuRow: Identifiable, Equatable {
    let id: MobileTerminalPreview.ID
    let name: String

    init(_ terminal: MobileTerminalPreview) {
        id = terminal.id
        name = terminal.name
    }
}

struct TerminalPickerMenuMembership: Equatable {
    let ids: [MobileTerminalPreview.ID]

    init(_ rows: [TerminalPickerMenuRow]) {
        ids = rows.map(\.id)
    }
}

extension Collection where Element == TerminalPickerMenuRow {
    func resolvedTerminalPickerSelection(
        selectedID: MobileTerminalPreview.ID?
    ) -> (id: MobileTerminalPreview.ID, name: String)? {
        if let selectedID, let selected = first(where: { $0.id == selectedID }) {
            return (id: selected.id, name: selected.name)
        }
        guard let first else { return nil }
        return (id: first.id, name: first.name)
    }
}

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
