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

    @Test func recentModeIgnoresStaleAndDuplicateHistoryEntries() {
        let current = UUID()
        let recent = UUID()
        let untouched = UUID()
        let stale = UUID()

        let ordered = CommandPaletteWorkspaceOrdering().orderedWorkspaceIDs(
            sidebarIDs: [current, recent, untouched],
            selectedID: current,
            recentIDs: [recent, stale, recent],
            mode: .recent
        )

        #expect(ordered == [recent, untouched, current])
    }

    @Test func recentModeFallsBackToSelectedFirstWithoutHistory() {
        let current = UUID()
        let other = UUID()

        let ordered = CommandPaletteWorkspaceOrdering().orderedWorkspaceIDs(
            sidebarIDs: [other, current],
            selectedID: current,
            recentIDs: [],
            mode: .recent
        )

        #expect(ordered == [current, other])
    }
}
