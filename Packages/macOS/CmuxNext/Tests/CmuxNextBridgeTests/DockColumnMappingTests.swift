import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing
@testable import CmuxNextBridge

/// `columns[].sticky` (`sticky-columns-v1`) reaches the layout; an older
/// daemon (no field) and a newer one (unknown values) both degrade.
struct DockColumnMappingTests {
    private func column(_ json: String) throws -> ColumnSnapshot {
        try JSONDecoder().decode(ColumnSnapshot.self, from: Data(json.utf8))
    }

    @Test func decodesEdgeAndMode() throws {
        let dock = try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"sticky":{"edge":"left","mode":"overlay"}}"#).dock
        #expect(dock == DockSnapshot(edge: .left, mode: .overlay))
        #expect(dock.map(LayoutMapping.dock) == DockColumn(edge: .left, mode: .overlay))
    }

    @Test func anOlderDaemonHasNoDockColumns() throws {
        #expect(try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4}}"#).dock == nil)
        #expect(try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"sticky":null}"#).dock == nil)
    }

    @Test func aDockArrivesInItsOwnFieldAndASideFlagCannotUseIt() throws {
        let dock = try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"dock":{"edge":"bottom","mode":"overlay"}}"#).dock
        #expect(dock == DockSnapshot(edge: .bottom, mode: .overlay))
        let misplaced = try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"dock":{"edge":"left","mode":"docked"}}"#).dock
        #expect(misplaced == nil)
    }

    @Test func unknownValuesFallBackToTheDefaults() throws {
        let dock = try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"sticky":{"edge":"diagonal","mode":"float"}}"#).dock
        #expect(dock == DockSnapshot(edge: .right, mode: .docked))
    }

    @Test func roundTripsThroughTheLayout() {
        for edge in DockEdge.allCases {
            for mode in DockMode.allCases {
                let dock = DockColumn(edge: edge, mode: mode)
                #expect(LayoutMapping.dock(LayoutMapping.snapshot(dock)) == dock)
            }
        }
    }
}
