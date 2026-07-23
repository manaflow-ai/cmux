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

    @Test func nonTerminalSurfacesAppearInTheirOwnRowsAndCanBeSelected() {
        let surface = MobileSurfacePreview(id: "surface-1", kind: .markdown, title: "README")
        let value = TerminalPickerMenuValue(
            liveTerminals: [MobileTerminalPreview(id: "terminal-1", name: "Shell")],
            liveSurfaces: [
                MobileSurfacePreview(id: "terminal-1", kind: .terminal, title: "Shell"),
                surface,
            ],
            snapshotRows: [],
            selectedID: "terminal-1",
            selectedMacSurfaceID: surface.id,
            canCreateWorkspace: true,
            hasActiveBrowser: false,
            isChatMode: false
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
                snapshotRows: [],
                selectedID: terminal.id,
                selectedMacSurfaceID: selectedMacSurfaceID,
                canCreateWorkspace: true,
                hasActiveBrowser: hasActiveBrowser,
                isChatMode: false
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

    private func menuValue(
        liveTerminals: [MobileTerminalPreview],
        snapshotRows: [TerminalPickerMenuRow],
        selectedID: MobileTerminalPreview.ID? = "terminal-1"
    ) -> TerminalPickerMenuValue {
        TerminalPickerMenuValue(
            liveTerminals: liveTerminals,
            snapshotRows: snapshotRows,
            selectedID: selectedID,
            canCreateWorkspace: true,
            hasActiveBrowser: false,
            isChatMode: false
        )
    }
}
