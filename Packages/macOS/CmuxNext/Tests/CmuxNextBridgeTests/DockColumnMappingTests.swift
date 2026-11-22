import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing
@testable import CmuxNextBridge

/// `columns[].dock` (`dock-columns-v1`) reaches the layout; an older
/// daemon (no field) and a newer one (unknown values) both degrade.
struct DockColumnMappingTests {
    private func column(_ json: String) throws -> ColumnSnapshot {
        try JSONDecoder().decode(ColumnSnapshot.self, from: Data(json.utf8))
    }

    @Test func decodesEdgeAndMode() throws {
        let dock = try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"dock":{"edge":"left","mode":"overlay"}}"#).dock
        #expect(dock == DockSnapshot(edge: .left, mode: .overlay))
        #expect(dock.map(LayoutMapping.dock) == DockColumn(edge: .left, mode: .overlay))
    }

    @Test func anOlderDaemonHasNoDockColumns() throws {
        #expect(try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4}}"#).dock == nil)
        #expect(try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"dock":null}"#).dock == nil)
    }

    @Test func everyEdgeArrivesInTheOneDockField() throws {
        let bottom = try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"dock":{"edge":"bottom","mode":"overlay"}}"#).dock
        #expect(bottom == DockSnapshot(edge: .bottom, mode: .overlay))
        let left = try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"dock":{"edge":"left","mode":"docked"}}"#).dock
        #expect(left == DockSnapshot(edge: .left, mode: .docked))
    }

    @Test func unknownValuesFallBackToTheDefaults() throws {
        let dock = try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"dock":{"edge":"diagonal","mode":"float"}}"#).dock
        #expect(dock == DockSnapshot(edge: .right, mode: .docked))
    }

    /// `dock-column-role-v1`: the agent chat role survives the trip through
    /// the layout model and back to the daemon; an unknown role is dropped.
    @Test func theAgentChatRoleSurvivesTheLayout() throws {
        func role(_ json: String) throws -> String? {
            let dock = try #require(try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"dock":"# + json + "}").dock)
            let request = SetColumnDockRequest(pane: 4, dock: LayoutMapping.snapshot(LayoutMapping.dock(dock)))
            let sent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
            return sent?["role"] as? String
        }
        #expect(try role(#"{"edge":"left","mode":"docked","role":"agent_chat"}"#) == "agent_chat")
        #expect(try role(#"{"edge":"left","mode":"docked","role":"notes"}"#) == nil)
        #expect(try role(#"{"edge":"left","mode":"docked"}"#) == nil)
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
