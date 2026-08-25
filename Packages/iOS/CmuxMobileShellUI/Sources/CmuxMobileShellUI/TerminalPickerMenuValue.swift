import CmuxMobileShellModel

/// Immutable state that determines the native terminal picker's presented menu.
struct TerminalPickerMenuValue: Equatable {
    let rows: [TerminalPickerMenuRow]
    let selectedID: MobileTerminalPreview.ID?
    let selectedMacSurfaceID: MobileSurfacePreview.ID?
    let selectedName: String?
    let canCreateWorkspace: Bool
    let hasActiveBrowser: Bool
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
        self.browserStreamRows = browserStreamRows
        self.supportsBrowserStream = supportsBrowserStream
        self.activeBrowserStreamPanelID = activeBrowserStreamPanelID
        self.simulatorStreamRows = simulatorStreamRows
        self.supportsSimulatorStream = supportsSimulatorStream
        self.activeSimulatorStreamPanelID = activeSimulatorStreamPanelID
    }

    /// The single row that carries the checkmark. Nil while the phone-local
    /// browser or a Mac browser stream overlays the workspace (the stream row
    /// draws its own check from `activeBrowserStreamPanelID`); a Mac-surface
    /// selection whose row has disappeared falls back to the resolved
    /// terminal, matching `selectedName`.
    var checkedRowID: TerminalPickerMenuRow.ID? {
        if hasActiveBrowser || activeBrowserStreamPanelID != nil || activeSimulatorStreamPanelID != nil { return nil }
        if let selectedMacSurfaceID,
           rows.contains(where: { $0.id == .macSurface(selectedMacSurfaceID) }) {
            return .macSurface(selectedMacSurfaceID)
        }
        return selectedID.map(TerminalPickerMenuRow.ID.terminal)
    }

    var terminalRows: [TerminalPickerMenuRow] {
        rows.filter { if case .terminal = $0.id { true } else { false } }
    }

    /// Mac-surface rows for the "Mac Surfaces" section. Browser panes are
    /// excluded whenever the Mac supports browser streaming — they get their
    /// own "Mac Browsers" section — and only fall back to a surface row on
    /// Macs without streaming. Filtered here (not at row construction) so
    /// snapshot-built rows obey the same policy as live ones.
    var macSurfaceRows: [TerminalPickerMenuRow] {
        rows.filter {
            guard case .macSurface = $0.id else { return false }
            return !(supportsBrowserStream && $0.surfaceKind == .browser)
        }
    }
}
