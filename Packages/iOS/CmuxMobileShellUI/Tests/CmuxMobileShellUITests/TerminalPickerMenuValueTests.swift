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
