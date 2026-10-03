import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing
@testable import CmuxNextBridge

/// `columns[].sticky` (`sticky-columns-v1`) reaches the layout; an older
/// daemon (no field) and a newer one (unknown values) both degrade.
struct StickyColumnMappingTests {
    private func column(_ json: String) throws -> ColumnSnapshot {
        try JSONDecoder().decode(ColumnSnapshot.self, from: Data(json.utf8))
    }

    @Test func decodesEdgeAndMode() throws {
        let sticky = try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"sticky":{"edge":"left","mode":"overlay"}}"#).sticky
        #expect(sticky == StickySnapshot(edge: .left, mode: .overlay))
        #expect(sticky.map(LayoutMapping.sticky) == StickyColumn(edge: .left, mode: .overlay))
    }

    @Test func anOlderDaemonHasNoStickyColumns() throws {
        #expect(try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4}}"#).sticky == nil)
        #expect(try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"sticky":null}"#).sticky == nil)
    }

    @Test func aDockArrivesInItsOwnFieldAndASideFlagCannotUseIt() throws {
        let dock = try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"dock":{"edge":"bottom","mode":"overlay"}}"#).sticky
        #expect(dock == StickySnapshot(edge: .bottom, mode: .overlay))
        let misplaced = try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"dock":{"edge":"left","mode":"docked"}}"#).sticky
        #expect(misplaced == nil)
    }

    @Test func unknownValuesFallBackToTheDefaults() throws {
        let sticky = try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"sticky":{"edge":"diagonal","mode":"float"}}"#).sticky
        #expect(sticky == StickySnapshot(edge: .right, mode: .docked))
    }

    @Test func roundTripsThroughTheLayout() {
        for edge in StickyEdge.allCases {
            for mode in StickyMode.allCases {
                let sticky = StickyColumn(edge: edge, mode: mode)
                #expect(LayoutMapping.sticky(LayoutMapping.snapshot(sticky)) == sticky)
            }
        }
    }
}
