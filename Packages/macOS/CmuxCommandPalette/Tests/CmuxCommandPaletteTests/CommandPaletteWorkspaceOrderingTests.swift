import Foundation
import Testing

@testable import CmuxCommandPalette

struct CommandPaletteWorkspaceOrderingTests {
    @Test func recentModePutsPreviousWorkspacesFirstAndCurrentLast() {
        let current = UUID()
        let previous = UUID()
        let older = UUID()
        let untouched = UUID()

        let ordered = CommandPaletteWorkspaceOrdering().orderedWorkspaceIDs(
            sidebarIDs: [current, older, previous, untouched],
            selectedID: current,
            recentIDs: [previous, older],
            mode: .recent
        )

        #expect(ordered == [previous, older, untouched, current])
    }

    @Test func sidebarModeKeepsSelectedWorkspaceFirst() {
        let current = UUID()
        let other = UUID()

        let ordered = CommandPaletteWorkspaceOrdering().orderedWorkspaceIDs(
            sidebarIDs: [other, current],
            selectedID: current,
            recentIDs: [other],
            mode: .sidebar
        )

        #expect(ordered == [current, other])
    }
}
