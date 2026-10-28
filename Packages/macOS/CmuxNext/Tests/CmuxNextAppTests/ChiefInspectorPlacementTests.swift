import Testing
@testable import CmuxNextApp

/// a243 "memory inspector keeps closing immediately": opened from Home, the
/// inspector went into a new column right of Home's full-width right column
/// (off screen) or into the pinned Chief dock (refused), so it seemed to
/// close at once. In Home it is a tab in the right column instead.
struct ChiefInspectorPlacementTests {
    typealias Placement = ChiefInspectorPlacement<String>

    /// Home as the user has it: the pinned Chief dock, then the right column.
    let home: [Placement.Column] = [
        .init(panes: ["dock"], isDock: true),
        .init(panes: ["right"], isDock: false),
    ]

    @Test func fromTheHomeChiefDockItOpensAsATabInTheRightColumn() {
        #expect(Placement.resolve(focused: "dock", inHome: true, columns: home) == .tab(in: "right"))
    }

    @Test func fromTheHomeRightColumnItOpensAsATabThere() {
        #expect(Placement.resolve(focused: "right", inHome: true, columns: home) == .tab(in: "right"))
    }

    @Test func aHomeWithoutAScrollingColumnFallsBackToAUserWorkspace() {
        #expect(Placement.resolve(focused: "dock", inHome: true, columns: [home[0]]) == nil)
    }

    @Test func outsideHomeItStillGetsANewColumn() {
        #expect(Placement.resolve(focused: "right", inHome: false, columns: home) == .newColumn(rightOf: "right"))
    }
}
