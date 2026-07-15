import CoreGraphics
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceListScrollPinModelTests {
    private let rowHeights: [WorkspaceListScrollPinKind: CGFloat] = [
        .workspaceRow: 92.5,
        .groupHeader: 44,
        .groupFooter: 16,
    ]

    @Test func flatListPinsToRowCountTimesHeight() {
        let model = WorkspaceListScrollPinModel(
            kinds: Array(repeating: .workspaceRow, count: 100),
            rowHeightsAreUniform: true
        )
        #expect(
            model.pinnedContentHeight(uniformHeights: rowHeights, variableHeights: [:]) == 9250
        )
    }

    @Test func groupedListSumsPerKindHeights() {
        let model = WorkspaceListScrollPinModel(
            kinds: [.groupHeader, .workspaceRow, .workspaceRow, .groupFooter, .workspaceRow],
            rowHeightsAreUniform: true
        )
        #expect(
            model.pinnedContentHeight(uniformHeights: rowHeights, variableHeights: [:])
                == 44 + 92.5 + 92.5 + 16 + 92.5
        )
    }

    @Test func chromeRowContributesItsRealizedHeight() {
        let model = WorkspaceListScrollPinModel(
            kinds: [.variable(id: "chrome.macStatusRow"), .workspaceRow],
            rowHeightsAreUniform: true
        )
        #expect(
            model.pinnedContentHeight(
                uniformHeights: rowHeights,
                variableHeights: ["chrome.macStatusRow": 71]
            ) == 71 + 92.5
        )
    }

    @Test func unrealizedVariableRowPausesPinning() {
        let model = WorkspaceListScrollPinModel(
            kinds: [.variable(id: "chrome.macStatusRow"), .workspaceRow],
            rowHeightsAreUniform: true
        )
        #expect(
            model.pinnedContentHeight(uniformHeights: rowHeights, variableHeights: [:]) == nil
        )
    }

    @Test func unmeasuredKindPausesPinning() {
        let model = WorkspaceListScrollPinModel(
            kinds: [.groupHeader, .workspaceRow],
            rowHeightsAreUniform: true
        )
        #expect(
            model.pinnedContentHeight(
                uniformHeights: [.workspaceRow: 92.5],
                variableHeights: [:]
            ) == nil
        )
    }

    @Test func nonUniformRowHeightsDisablePinning() {
        let model = WorkspaceListScrollPinModel(
            kinds: Array(repeating: .workspaceRow, count: 3),
            rowHeightsAreUniform: false
        )
        #expect(
            model.pinnedContentHeight(uniformHeights: rowHeights, variableHeights: [:]) == nil
        )
    }

    @Test func emptyListPausesPinning() {
        let model = WorkspaceListScrollPinModel(kinds: [], rowHeightsAreUniform: true)
        #expect(
            model.pinnedContentHeight(uniformHeights: rowHeights, variableHeights: [:]) == nil
        )
    }
}
