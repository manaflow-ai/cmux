import CmuxMobileShellModel
import CmuxMobileSupport

/// Immutable state that determines the native terminal picker's presented menu.
struct TerminalPickerMenuValue: Equatable {
    let rows: [TerminalPickerMenuRow]
    let selectedID: MobileTerminalPreview.ID?
    let selectedName: String?
    let canCreateWorkspace: Bool
    let isChatMode: Bool
    let chatDestination: SurfaceSwitcherDestination?
    let localBrowserDestination: SurfaceSwitcherDestination?
    let browserStreamRows: [BrowserStreamPickerRow]
    let supportsBrowserStream: Bool
    let activeBrowserStreamPanelID: String?
    let browserRefreshState: SurfaceSwitcherBrowserRefreshState
    let destinations: [SurfaceSwitcherDestination]
    let activeDestinationID: SurfaceSwitcherDestination.ID?

    init(
        liveTerminals: [MobileTerminalPreview],
        snapshotRows: [TerminalPickerMenuRow],
        selectedID: MobileTerminalPreview.ID?,
        canCreateWorkspace: Bool,
        isChatMode: Bool,
        chatDestination: SurfaceSwitcherDestination? = nil,
        localBrowserDestination: SurfaceSwitcherDestination? = nil,
        browserStreamRows: [BrowserStreamPickerRow] = [],
        supportsBrowserStream: Bool = false,
        activeBrowserStreamPanelID: String? = nil,
        browserRefreshState: SurfaceSwitcherBrowserRefreshState = .idle
    ) {
        rows = snapshotRows.isEmpty
            ? liveTerminals.map(TerminalPickerMenuRow.init)
            : snapshotRows
        let selection = rows.resolvedTerminalPickerSelection(selectedID: selectedID)
        self.selectedID = selection?.id
        selectedName = selection?.name
        self.canCreateWorkspace = canCreateWorkspace
        self.isChatMode = isChatMode
        self.chatDestination = chatDestination
        self.localBrowserDestination = localBrowserDestination
        self.browserStreamRows = browserStreamRows
        self.supportsBrowserStream = supportsBrowserStream
        self.activeBrowserStreamPanelID = activeBrowserStreamPanelID
        self.browserRefreshState = browserRefreshState

        let terminalDestinations = rows.map { row in
            SurfaceSwitcherDestination(
                kind: .terminal(row.id),
                title: row.name,
                subtitle: L10n.string("mobile.switchTab.source.terminal", defaultValue: "Terminal"),
                systemImage: "terminal",
                accessibilityIdentifier: "MobileTerminalMenuItem-\(row.id.rawValue)"
            )
        }
        let streamDestinations = browserStreamRows.map(\.destination)
        destinations = terminalDestinations
            + [chatDestination].compactMap { $0 }
            + [localBrowserDestination].compactMap { $0 }
            + streamDestinations

        if isChatMode, let chatDestination {
            activeDestinationID = chatDestination.id
        } else if let localBrowserDestination {
            activeDestinationID = localBrowserDestination.id
        } else if let activeBrowserStreamPanelID,
                  let stream = browserStreamRows.first(where: { $0.id == activeBrowserStreamPanelID }) {
            activeDestinationID = stream.destination.id
        } else if let selectedID = selection?.id {
            activeDestinationID = SurfaceSwitcherDestination.Kind.terminal(selectedID).id
        } else {
            activeDestinationID = nil
        }
    }

    var activeDestination: SurfaceSwitcherDestination? {
        guard let activeDestinationID else { return nil }
        return destinations.first { $0.id == activeDestinationID }
    }

    var shouldShowSearch: Bool {
        destinations.count >= 8
    }

    func filteredDestinations(searchText: String) -> [SurfaceSwitcherDestination] {
        destinations.filter { $0.matchesSearch(searchText) }
    }
}
