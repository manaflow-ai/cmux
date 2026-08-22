import CmuxMobileShellModel

/// Immutable state that determines the native terminal picker's presented menu.
struct TerminalPickerMenuValue: Equatable {
    let rows: [TerminalPickerMenuRow]
    let selectedID: MobileTerminalPreview.ID?
    let selectedMacSurfaceID: MobileSurfacePreview.ID?
    let selectedName: String?
    let checkedRowID: TerminalPickerMenuRow.ID?
    let macSurfaceRows: [TerminalPickerMenuRow]
    let canCreateWorkspace: Bool
    let hasActiveBrowser: Bool
    let isChatMode: Bool
    let browserStreamRows: [BrowserStreamPickerRow]
    let supportsBrowserStream: Bool
    let activeBrowserStreamPanelID: String?
    let simulatorStreamRows: [SimulatorStreamPickerRow]
    let supportsSimulatorStream: Bool
    let activeSimulatorStreamPanelID: String?

    init(
        liveTerminals: [MobileTerminalPreview],
        liveSurfaces: [MobileSurfacePreview] = [],
        snapshotRows: [TerminalPickerMenuRow],
        selectedID: MobileTerminalPreview.ID?,
        selectedMacSurfaceID: MobileSurfacePreview.ID? = nil,
        canCreateWorkspace: Bool,
        hasActiveBrowser: Bool,
        isChatMode: Bool,
        browserStreamRows: [BrowserStreamPickerRow] = [],
        supportsBrowserStream: Bool = false,
        activeBrowserStreamPanelID: String? = nil,
        simulatorStreamRows: [SimulatorStreamPickerRow] = [],
        supportsSimulatorStream: Bool = false,
        activeSimulatorStreamPanelID: String? = nil
    ) {
        let resolvedRows = snapshotRows.isEmpty
            ? liveTerminals.map(TerminalPickerMenuRow.init)
                + liveSurfaces.filter { !$0.kind.isTerminal }.map(TerminalPickerMenuRow.init)
            : snapshotRows
        rows = resolvedRows
        let selection = resolvedRows.resolvedTerminalPickerSelection(selectedID: selectedID)
        self.selectedID = selection?.id
        self.selectedMacSurfaceID = selectedMacSurfaceID
        selectedName = selectedMacSurfaceID.flatMap { id in
            resolvedRows.first(where: { $0.id == .macSurface(id) })?.name
        } ?? selection?.name
        self.canCreateWorkspace = canCreateWorkspace
        self.hasActiveBrowser = hasActiveBrowser
        self.isChatMode = isChatMode
        self.browserStreamRows = browserStreamRows
        self.supportsBrowserStream = supportsBrowserStream
        self.activeBrowserStreamPanelID = activeBrowserStreamPanelID
        self.simulatorStreamRows = simulatorStreamRows
        self.supportsSimulatorStream = supportsSimulatorStream
        self.activeSimulatorStreamPanelID = activeSimulatorStreamPanelID

        var streamBackedSurfaceIDs: Set<MobileSurfacePreview.ID> = []
        if supportsBrowserStream {
            streamBackedSurfaceIDs.formUnion(browserStreamRows.map { .init(rawValue: $0.id) })
        }
        if supportsSimulatorStream {
            streamBackedSurfaceIDs.formUnion(simulatorStreamRows.map { .init(rawValue: $0.id) })
        }
        let filteredMacSurfaceRows = resolvedRows.filter {
            guard let surfaceID = $0.macSurfaceID else { return false }
            return !streamBackedSurfaceIDs.contains(surfaceID)
        }
        macSurfaceRows = filteredMacSurfaceRows
        if hasActiveBrowser || activeBrowserStreamPanelID != nil || activeSimulatorStreamPanelID != nil {
            checkedRowID = nil
        } else if let selectedMacSurfaceID,
                  filteredMacSurfaceRows.contains(where: { $0.id == .macSurface(selectedMacSurfaceID) }) {
            checkedRowID = .macSurface(selectedMacSurfaceID)
        } else {
            checkedRowID = selection.map { .terminal($0.id) }
        }
    }

    var terminalRows: [TerminalPickerMenuRow] {
        rows.filter { if case .terminal = $0.id { true } else { false } }
    }
}
