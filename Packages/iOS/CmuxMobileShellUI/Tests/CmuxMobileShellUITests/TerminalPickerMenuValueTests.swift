import CMUXMobileCore
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct TerminalPickerMenuValueTests {
    @Test func viewportChurnDoesNotChangeMenuValueButTitlesAndMembershipDo() {
        let terminal = MobileTerminalPreview(id: "terminal-1", name: "Build")
        let baseline = menuValue(liveTerminals: [terminal])

        var titleOnlyTerminal = terminal
        titleOnlyTerminal.name = "Build output"
        let titleOnlyChange = menuValue(liveTerminals: [titleOnlyTerminal])

        var viewportOnlyTerminal = terminal
        viewportOnlyTerminal.viewportFit = MobileTerminalViewportFit(
            effective: MobileTerminalViewportSize(columns: 80, rows: 24),
            client: MobileTerminalViewportSize(columns: 100, rows: 30),
            isCurrentClientLimiting: false
        )
        let viewportOnlyChange = menuValue(liveTerminals: [viewportOnlyTerminal])

        let addedTerminal = MobileTerminalPreview(id: "terminal-2", name: "Tests")
        let membershipChange = menuValue(
            liveTerminals: [viewportOnlyTerminal, addedTerminal]
        )

        #expect(titleOnlyChange != baseline)
        #expect(viewportOnlyChange == baseline)
        #expect(membershipChange != baseline)
    }

    @Test func selectionIsResolvedFromTheRowsDisplayedByTheMenu() {
        let liveTerminals = [
            MobileTerminalPreview(id: "terminal-first", name: "First"),
            MobileTerminalPreview(id: "terminal-selected", name: "Selected"),
        ]

        let selected = menuValue(
            liveTerminals: liveTerminals,
            selectedID: "terminal-selected"
        )
        let staleSelection = menuValue(
            liveTerminals: liveTerminals,
            selectedID: "terminal-missing"
        )

        #expect(selected.selectedID == MobileTerminalPreview.ID(rawValue: "terminal-selected"))
        #expect(selected.selectedName == "Selected")
        #expect(staleSelection.selectedID == MobileTerminalPreview.ID(rawValue: "terminal-first"))
        #expect(staleSelection.selectedName == "First")
    }

    @Test func valueUsesLiveRowsAndHandlesNoTerminals() {
        let liveTerminal = MobileTerminalPreview(id: "terminal-live", name: "Live")
        let firstOpen = menuValue(
            liveTerminals: [liveTerminal],
            selectedID: "missing"
        )
        let noTerminals = menuValue(liveTerminals: [], selectedID: "missing")

        #expect(firstOpen.rows == [TerminalPickerMenuRow(liveTerminal)])
        #expect(firstOpen.selectedID == liveTerminal.id)
        #expect(firstOpen.selectedName == liveTerminal.name)
        #expect(noTerminals.rows.isEmpty)
        #expect(noTerminals.selectedID == nil)
        #expect(noTerminals.selectedName == nil)
    }

    @Test func nonTerminalSurfacesAppearInTheirOwnRowsAndCanBeSelected() {
        let surface = MobileSurfacePreview(id: "surface-1", kind: .markdown, title: "README")
        let value = TerminalPickerMenuValue(
            liveTerminals: [MobileTerminalPreview(id: "terminal-1", name: "Shell")],
            liveSurfaces: [
                MobileSurfacePreview(id: "terminal-1", kind: .terminal, title: "Shell"),
                surface,
            ],
            selectedID: "terminal-1",
            selectedMacSurfaceID: surface.id,
            canCreateWorkspace: true,
            hasActiveBrowser: false
        )
        #expect(value.terminalRows.count == 1)
        #expect(value.macSurfaceRows == [TerminalPickerMenuRow(surface)])
        #expect(value.selectedName == "README")
    }

    @Test func exactlyOneRowCarriesTheCheckmark() {
        let terminal = MobileTerminalPreview(id: "terminal-1", name: "Shell")
        let surface = MobileSurfacePreview(id: "surface-1", kind: .todo, title: "Todos")
        func value(
            selectedMacSurfaceID: MobileSurfacePreview.ID?,
            hasActiveBrowser: Bool = false,
            liveSurfaces: [MobileSurfacePreview]? = nil
        ) -> TerminalPickerMenuValue {
            TerminalPickerMenuValue(
                liveTerminals: [terminal],
                liveSurfaces: liveSurfaces ?? [
                    MobileSurfacePreview(id: "terminal-1", kind: .terminal, title: "Shell"),
                    surface,
                ],
                selectedID: terminal.id,
                selectedMacSurfaceID: selectedMacSurfaceID,
                canCreateWorkspace: true,
                hasActiveBrowser: hasActiveBrowser
            )
        }

        // Mac surface selected: its row is checked, the terminal row is not.
        #expect(value(selectedMacSurfaceID: surface.id).checkedRowID == .macSurface(surface.id))
        // No surface selection: the resolved terminal is checked.
        #expect(value(selectedMacSurfaceID: nil).checkedRowID == .terminal(terminal.id))
        // Phone browser overlay owns the screen: nothing is checked.
        #expect(value(selectedMacSurfaceID: surface.id, hasActiveBrowser: true).checkedRowID == nil)
        // Stale surface selection (row gone) falls back to the terminal row.
        #expect(
            value(
                selectedMacSurfaceID: surface.id,
                liveSurfaces: [MobileSurfacePreview(id: "terminal-1", kind: .terminal, title: "Shell")]
            ).checkedRowID == .terminal(terminal.id)
        )
    }

    @Test func browserSurfacesLeaveMacSurfacesWhenTheMacStreamsBrowsers() {
        let browser = MobileSurfacePreview(id: "surface-web", kind: .browser, title: "cmux.com")
        let markdown = MobileSurfacePreview(id: "surface-md", kind: .markdown, title: "README")
        func value(supportsBrowserStream: Bool) -> TerminalPickerMenuValue {
            TerminalPickerMenuValue(
                liveTerminals: [],
                liveSurfaces: [browser, markdown],
                selectedID: nil,
                canCreateWorkspace: true,
                hasActiveBrowser: false,
                supportsBrowserStream: supportsBrowserStream
            )
        }

        let streaming = value(supportsBrowserStream: true)
        #expect(streaming.macSurfaceRows.map(\.id) == [.macSurface(markdown.id)])
        let legacyMac = value(supportsBrowserStream: false)
        #expect(legacyMac.macSurfaceRows.map(\.id) == [.macSurface(browser.id), .macSurface(markdown.id)])
    }

    /// SSH computers' browser tabs are not on a Mac, so the switcher's
    /// browser section is named by the computer's kind.
    @Test func browserSectionIsNamedByComputerKind() {
        let terminal = MobileTerminalPreview(id: "terminal-1", name: "Shell 1")
        func value(isSSHComputer: Bool) -> TerminalPickerMenuValue {
            TerminalPickerMenuValue(
                liveTerminals: [terminal],
                selectedID: terminal.id,
                canCreateWorkspace: true,
                hasActiveBrowser: false,
                supportsBrowserStream: true,
                isSSHComputer: isSSHComputer
            )
        }
        #expect(value(isSSHComputer: false).browserSectionTitle == "Mac Browsers")
        #expect(value(isSSHComputer: true).browserSectionTitle == "Browsers")
        // The next opening uses the current computer kind.
        #expect(value(isSSHComputer: false) != value(isSSHComputer: true))
    }

    @Test func onDeviceStreamedTabKeepsItsBrowserRowChecked() {
        let rows = ["panel-1", "panel-2"].map { id in
            BrowserStreamPickerRow(MobileBrowserPanelDescriptor(
                panelID: id, workspaceID: "ws", url: "http://localhost:8765/", title: id,
                pageWidth: 0, pageHeight: 0, canGoBack: false, canGoForward: false, isLoading: false
            ))
        }
        func value(hasActiveBrowser: Bool, streamed: String? = nil, onDevice: String? = nil) -> TerminalPickerMenuValue {
            TerminalPickerMenuValue(
                liveTerminals: [MobileTerminalPreview(id: "terminal-1", name: "Build")],
                selectedID: "terminal-1",
                canCreateWorkspace: true,
                hasActiveBrowser: hasActiveBrowser,
                browserStreamRows: rows,
                supportsBrowserStream: true,
                activeBrowserStreamPanelID: streamed,
                onDeviceBrowserStreamPanelID: onDevice
            )
        }

        // Streamed and On iPhone check the same tab row, never New Browser.
        let streamed = value(hasActiveBrowser: false, streamed: "panel-2")
        let onDevice = value(hasActiveBrowser: true, onDevice: "panel-2")
        #expect(streamed.checkedBrowserStreamPanelID == "panel-2")
        #expect(onDevice.checkedBrowserStreamPanelID == "panel-2")
        #expect(onDevice.checksNewBrowser == false)
        #expect(onDevice.checkedRowID == nil)

        // A plain phone-local browser is New Browser.
        let plain = value(hasActiveBrowser: true)
        #expect(plain.checkedBrowserStreamPanelID == nil)
        #expect(plain.checksNewBrowser)

        // A tab the Mac closed leaves New Browser checked; a stale link
        // without a visible browser checks nothing.
        #expect(value(hasActiveBrowser: true, onDevice: "gone").checksNewBrowser)
        let hidden = value(hasActiveBrowser: false, onDevice: "panel-1")
        #expect(hidden.checkedBrowserStreamPanelID == nil)
        #expect(hidden.checksNewBrowser == false)
    }

    private func menuValue(
        liveTerminals: [MobileTerminalPreview],
        selectedID: MobileTerminalPreview.ID? = "terminal-1"
    ) -> TerminalPickerMenuValue {
        TerminalPickerMenuValue(
            liveTerminals: liveTerminals,
            selectedID: selectedID,
            canCreateWorkspace: true,
            hasActiveBrowser: false
        )
    }
}
