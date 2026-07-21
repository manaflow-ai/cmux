import CMUXMobileCore
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct TerminalPickerMenuValueTests {
    @Test func previewChurnDoesNotChangeSeededMenuValueButMembershipDoes() {
        let terminal = MobileTerminalPreview(id: "terminal-1", name: "Build")
        let snapshotRows = [TerminalPickerMenuRow(terminal)]
        let baseline = menuValue(liveTerminals: [terminal], snapshotRows: snapshotRows)

        var titleOnlyTerminal = terminal
        titleOnlyTerminal.name = "Build output"
        let titleOnlyChange = menuValue(liveTerminals: [titleOnlyTerminal], snapshotRows: snapshotRows)

        var viewportOnlyTerminal = terminal
        viewportOnlyTerminal.viewportFit = MobileTerminalViewportFit(
            effective: MobileTerminalViewportSize(columns: 80, rows: 24),
            client: MobileTerminalViewportSize(columns: 100, rows: 30),
            isCurrentClientLimiting: false
        )
        let viewportOnlyChange = menuValue(liveTerminals: [viewportOnlyTerminal], snapshotRows: snapshotRows)

        let addedTerminal = MobileTerminalPreview(id: "terminal-2", name: "Tests")
        let membershipRows = snapshotRows + [TerminalPickerMenuRow(addedTerminal)]
        let membershipChange = menuValue(
            liveTerminals: [viewportOnlyTerminal, addedTerminal],
            snapshotRows: membershipRows
        )

        #expect(titleOnlyChange == baseline)
        #expect(viewportOnlyChange == baseline)
        #expect(membershipChange != baseline)
    }

    @Test func selectionIsResolvedFromTheRowsDisplayedByTheMenu() {
        let liveTerminals = [
            MobileTerminalPreview(id: "terminal-live", name: "Live")
        ]
        let snapshotRows = [
            TerminalPickerMenuRow(MobileTerminalPreview(id: "terminal-snapshot", name: "Snapshot")),
            TerminalPickerMenuRow(MobileTerminalPreview(id: "terminal-selected", name: "Selected")),
        ]

        let selected = menuValue(
            liveTerminals: liveTerminals,
            snapshotRows: snapshotRows,
            selectedID: "terminal-selected"
        )
        let staleSelection = menuValue(
            liveTerminals: liveTerminals,
            snapshotRows: snapshotRows,
            selectedID: "terminal-live"
        )

        #expect(selected.selectedID == MobileTerminalPreview.ID(rawValue: "terminal-selected"))
        #expect(selected.selectedName == "Selected")
        #expect(staleSelection.selectedID == MobileTerminalPreview.ID(rawValue: "terminal-snapshot"))
        #expect(staleSelection.selectedName == "Snapshot")
    }

    @Test func emptySnapshotUsesLiveRowsAndHandlesNoTerminals() {
        let liveTerminal = MobileTerminalPreview(id: "terminal-live", name: "Live")
        let firstOpen = menuValue(
            liveTerminals: [liveTerminal],
            snapshotRows: [],
            selectedID: "missing"
        )
        let noTerminals = menuValue(liveTerminals: [], snapshotRows: [], selectedID: "missing")

        #expect(firstOpen.rows == [TerminalPickerMenuRow(liveTerminal)])
        #expect(firstOpen.selectedID == liveTerminal.id)
        #expect(firstOpen.selectedName == liveTerminal.name)
        #expect(noTerminals.rows.isEmpty)
        #expect(noTerminals.selectedID == nil)
        #expect(noTerminals.selectedName == nil)
    }

    @Test func browserStreamRowsAndActiveSelectionArePreserved() {
        let browserRows = [
            BrowserStreamPickerRow(browserDescriptor(panelID: "browser-build", title: "Build Preview"))
        ]
        let value = menuValue(
            liveTerminals: [MobileTerminalPreview(id: "terminal-live", name: "Live")],
            snapshotRows: [],
            selectedID: "terminal-live",
            browserStreamRows: browserRows,
            supportsBrowserStream: true,
            activeBrowserStreamPanelID: "browser-build"
        )

        #expect(value.browserStreamRows == browserRows)
        #expect(value.supportsBrowserStream)
        #expect(value.activeBrowserStreamPanelID == "browser-build")
        #expect(value.selectedID == MobileTerminalPreview.ID(rawValue: "terminal-live"))
        #expect(value.activeDestinationID == "browser-stream:browser-build")
    }

    @Test func browserStreamPickerRowLabelFallsBackFromTitleToHostURLAndPanelID() {
        #expect(BrowserStreamPickerRow(browserDescriptor(panelID: "panel-title", title: "  Docs  ")).label == "Docs")
        #expect(BrowserStreamPickerRow(browserDescriptor(panelID: "panel-host", title: "", url: "https://example.com/path")).label == "example.com")
        #expect(BrowserStreamPickerRow(browserDescriptor(panelID: "panel-url", title: nil, url: "notaurl")).label == "notaurl")
        #expect(BrowserStreamPickerRow(browserDescriptor(panelID: "panel-id", title: nil, url: nil)).label == "panel-id")
    }

    @Test func activeDestinationFollowsChatLocalBrowserStreamThenTerminal() {
        let terminal = MobileTerminalPreview(id: "terminal-live", name: "Live")
        let chat = SurfaceSwitcherDestination(
            kind: .chat("chat-1"),
            title: "Fix bug",
            subtitle: "Agent Chat",
            systemImage: "bubble.left.and.bubble.right",
            accessibilityIdentifier: "MobileAgentChatMenuItem-chat-1"
        )
        let localBrowser = SurfaceSwitcherDestination(
            kind: .localBrowser("browser-local"),
            title: "Docs",
            subtitle: "cmux.dev",
            systemImage: "globe",
            accessibilityIdentifier: "MobileLocalBrowserMenuItem-browser-local"
        )
        let stream = BrowserStreamPickerRow(browserDescriptor(panelID: "browser-stream", title: "Preview"))

        #expect(menuValue(
            liveTerminals: [terminal],
            snapshotRows: [],
            selectedID: terminal.id,
            chatDestination: chat,
            localBrowserDestination: localBrowser,
            browserStreamRows: [stream],
            supportsBrowserStream: true,
            activeBrowserStreamPanelID: "browser-stream",
            isChatMode: true
        ).activeDestinationID == "chat:chat-1")

        #expect(menuValue(
            liveTerminals: [terminal],
            snapshotRows: [],
            selectedID: terminal.id,
            chatDestination: chat,
            localBrowserDestination: localBrowser,
            browserStreamRows: [stream],
            supportsBrowserStream: true,
            activeBrowserStreamPanelID: "browser-stream"
        ).activeDestinationID == "local-browser:browser-local")

        #expect(menuValue(
            liveTerminals: [terminal],
            snapshotRows: [],
            selectedID: terminal.id,
            browserStreamRows: [stream],
            supportsBrowserStream: true,
            activeBrowserStreamPanelID: "browser-stream"
        ).activeDestinationID == "browser-stream:browser-stream")

        #expect(menuValue(
            liveTerminals: [terminal],
            snapshotRows: [],
            selectedID: terminal.id
        ).activeDestinationID == "terminal:terminal-live")
    }

    @Test func searchStartsAtEightDestinationsAndFiltersTitlesAndSubtitles() {
        let seven = menuValue(
            liveTerminals: terminals(count: 7),
            snapshotRows: [],
            selectedID: "terminal-1"
        )
        let eight = menuValue(
            liveTerminals: terminals(count: 8),
            snapshotRows: [],
            selectedID: "terminal-1"
        )
        let withBrowserSubtitle = menuValue(
            liveTerminals: terminals(count: 7),
            snapshotRows: [],
            selectedID: "terminal-1",
            browserStreamRows: [
                BrowserStreamPickerRow(browserDescriptor(panelID: "browser-docs", title: "Reference", url: "https://docs.cmux.dev"))
            ],
            supportsBrowserStream: true
        )

        #expect(!seven.shouldShowSearch)
        #expect(eight.shouldShowSearch)
        #expect(withBrowserSubtitle.shouldShowSearch)
        #expect(withBrowserSubtitle.filteredDestinations(searchText: "docs.cmux.dev").map(\.id) == ["browser-stream:browser-docs"])
    }

    @Test func duplicateLongTitlesKeepStableTypeScopedIDs() {
        let duplicateName = "A very long duplicated terminal title that should wrap without changing identity"
        let value = menuValue(
            liveTerminals: [
                MobileTerminalPreview(id: "terminal-a", name: duplicateName),
                MobileTerminalPreview(id: "terminal-b", name: duplicateName),
            ],
            snapshotRows: [],
            selectedID: "terminal-b",
            browserStreamRows: [
                BrowserStreamPickerRow(browserDescriptor(panelID: "browser-a", title: duplicateName)),
                BrowserStreamPickerRow(browserDescriptor(panelID: "browser-b", title: duplicateName)),
            ],
            supportsBrowserStream: true
        )

        #expect(value.destinations.map(\.id) == [
            "terminal:terminal-a",
            "terminal:terminal-b",
            "browser-stream:browser-a",
            "browser-stream:browser-b",
        ])
        #expect(value.activeDestinationID == "terminal:terminal-b")
    }

    @Test func destinationCountsCoverOneEightTwentyFourTerminalsAndZeroSevenTwentyFourBrowsers() {
        #expect(menuValue(liveTerminals: terminals(count: 1), snapshotRows: []).destinations.count == 1)
        #expect(menuValue(liveTerminals: terminals(count: 8), snapshotRows: []).destinations.count == 8)
        #expect(menuValue(liveTerminals: terminals(count: 24), snapshotRows: []).destinations.count == 24)
        #expect(menuValue(liveTerminals: [], snapshotRows: [], browserStreamRows: browserRows(count: 0), supportsBrowserStream: true).destinations.count == 0)
        #expect(menuValue(liveTerminals: [], snapshotRows: [], browserStreamRows: browserRows(count: 7), supportsBrowserStream: true).destinations.count == 7)
        #expect(menuValue(liveTerminals: [], snapshotRows: [], browserStreamRows: browserRows(count: 24), supportsBrowserStream: true).destinations.count == 24)
    }

    #if DEBUG
    @Test func debugPreviewFixtureIsDeterministicAndSearchable() {
        let value = SurfaceSwitcherPreviewFixture.value()

        #expect(value.destinations.count == 16)
        #expect(value.shouldShowSearch)
        #expect(value.activeDestinationID == "browser-stream:browser-stream-7")
        #expect(value.filteredDestinations(searchText: "preview-7.cmux.dev").map(\.id) == ["browser-stream:browser-stream-7"])
    }
    #endif

    private func menuValue(
        liveTerminals: [MobileTerminalPreview],
        snapshotRows: [TerminalPickerMenuRow],
        selectedID: MobileTerminalPreview.ID? = "terminal-1",
        isChatMode: Bool = false,
        chatDestination: SurfaceSwitcherDestination? = nil,
        localBrowserDestination: SurfaceSwitcherDestination? = nil,
        browserStreamRows: [BrowserStreamPickerRow] = [],
        supportsBrowserStream: Bool = false,
        activeBrowserStreamPanelID: String? = nil,
        browserRefreshState: SurfaceSwitcherBrowserRefreshState = .idle
    ) -> TerminalPickerMenuValue {
        TerminalPickerMenuValue(
            liveTerminals: liveTerminals,
            snapshotRows: snapshotRows,
            selectedID: selectedID,
            canCreateWorkspace: true,
            isChatMode: isChatMode,
            chatDestination: chatDestination,
            localBrowserDestination: localBrowserDestination,
            browserStreamRows: browserStreamRows,
            supportsBrowserStream: supportsBrowserStream,
            activeBrowserStreamPanelID: activeBrowserStreamPanelID,
            browserRefreshState: browserRefreshState
        )
    }

    private func terminals(count: Int) -> [MobileTerminalPreview] {
        (1...count).map { index in
            MobileTerminalPreview(id: "terminal-\(index)", name: "Terminal \(index)")
        }
    }

    private func browserRows(count: Int) -> [BrowserStreamPickerRow] {
        guard count > 0 else { return [] }
        return (1...count).map { index in
            BrowserStreamPickerRow(browserDescriptor(panelID: "browser-\(index)", title: "Browser \(index)"))
        }
    }

    private func browserDescriptor(
        panelID: String,
        title: String?,
        url: String? = "https://cmux.dev"
    ) -> MobileBrowserPanelDescriptor {
        MobileBrowserPanelDescriptor(
            panelID: panelID,
            workspaceID: "workspace-main",
            url: url,
            title: title,
            pageWidth: 1200,
            pageHeight: 800,
            canGoBack: false,
            canGoForward: false,
            isLoading: false
        )
    }
}
