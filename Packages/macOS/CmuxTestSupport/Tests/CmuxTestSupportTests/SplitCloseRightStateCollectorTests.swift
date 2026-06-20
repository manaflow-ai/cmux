#if DEBUG
import Foundation
import Testing
@testable import CmuxTestSupport

@Suite("SplitCloseRightStateCollector")
struct SplitCloseRightStateCollectorTests {
    private func terminalPane(
        attached: Bool = true,
        zeroSize: Bool = false,
        surfaceNil: Bool = false
    ) -> SplitCloseRightPaneSnapshot {
        SplitCloseRightPaneSnapshot(
            hasSelectedTab: true,
            hasPanelMapping: true,
            isTerminal: true,
            isAttached: attached,
            isZeroSize: zeroSize,
            isSurfaceNil: surfaceNil
        )
    }

    @Test func settledTwoPaneLayoutReportsSettledWithExactCounts() {
        let result = SplitCloseRightStateCollector().collect(
            paneSnapshots: [terminalPane(), terminalPane()],
            bonsplitTabCount: 2,
            panelCount: 2,
            emptyPanelAppearCount: 0
        )

        #expect(result.settled)
        #expect(result.data["finalPaneCount"] == "2")
        #expect(result.data["finalBonsplitTabCount"] == "2")
        #expect(result.data["finalPanelCount"] == "2")
        #expect(result.data["missingSelectedTabCount"] == "0")
        #expect(result.data["missingPanelMappingCount"] == "0")
        #expect(result.data["emptyPanelAppearCount"] == "0")
        #expect(result.data["selectedTerminalCount"] == "2")
        #expect(result.data["selectedTerminalAttachedCount"] == "2")
        #expect(result.data["selectedTerminalZeroSizeCount"] == "0")
        #expect(result.data["selectedTerminalSurfaceNilCount"] == "0")
    }

    @Test func nonZeroEmptyPanelAppearCountBlocksSettle() {
        let result = SplitCloseRightStateCollector().collect(
            paneSnapshots: [terminalPane(), terminalPane()],
            bonsplitTabCount: 2,
            panelCount: 2,
            emptyPanelAppearCount: 1
        )

        #expect(!result.settled)
        #expect(result.data["emptyPanelAppearCount"] == "1")
    }

    @Test func threePanesNeverSettlesAndCountsAllTerminals() {
        let result = SplitCloseRightStateCollector().collect(
            paneSnapshots: [terminalPane(), terminalPane(), terminalPane()],
            bonsplitTabCount: 3,
            panelCount: 3,
            emptyPanelAppearCount: 0
        )

        #expect(!result.settled)
        #expect(result.data["finalPaneCount"] == "3")
        #expect(result.data["selectedTerminalCount"] == "3")
    }

    @Test func missingSelectedTabAndMappingAreTalliedAndBlockSettle() {
        let result = SplitCloseRightStateCollector().collect(
            paneSnapshots: [
                SplitCloseRightPaneSnapshot(hasSelectedTab: false),
                SplitCloseRightPaneSnapshot(hasSelectedTab: true, hasPanelMapping: false),
            ],
            bonsplitTabCount: 1,
            panelCount: 1,
            emptyPanelAppearCount: 0
        )

        #expect(!result.settled)
        #expect(result.data["missingSelectedTabCount"] == "1")
        #expect(result.data["missingPanelMappingCount"] == "1")
        #expect(result.data["selectedTerminalCount"] == "0")
    }

    @Test func unattachedZeroSizeAndNilSurfaceTerminalsAreCountedButBlockSettle() {
        let result = SplitCloseRightStateCollector().collect(
            paneSnapshots: [
                terminalPane(attached: false, zeroSize: true, surfaceNil: true),
                terminalPane(),
            ],
            bonsplitTabCount: 2,
            panelCount: 2,
            emptyPanelAppearCount: 0
        )

        #expect(!result.settled)
        #expect(result.data["selectedTerminalCount"] == "2")
        #expect(result.data["selectedTerminalAttachedCount"] == "1")
        #expect(result.data["selectedTerminalZeroSizeCount"] == "1")
        #expect(result.data["selectedTerminalSurfaceNilCount"] == "1")
    }

    @Test func nonTerminalMappedPaneCountsTowardNeitherSettleNorTerminals() {
        let result = SplitCloseRightStateCollector().collect(
            paneSnapshots: [
                SplitCloseRightPaneSnapshot(hasSelectedTab: true, hasPanelMapping: true, isTerminal: false),
                terminalPane(),
            ],
            bonsplitTabCount: 2,
            panelCount: 2,
            emptyPanelAppearCount: 0
        )

        #expect(!result.settled)
        #expect(result.data["missingSelectedTabCount"] == "0")
        #expect(result.data["missingPanelMappingCount"] == "0")
        #expect(result.data["selectedTerminalCount"] == "1")
    }
}
#endif
