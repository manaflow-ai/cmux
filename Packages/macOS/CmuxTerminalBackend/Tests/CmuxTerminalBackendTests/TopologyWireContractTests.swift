import CmuxTerminalBackend
import Foundation
import Testing

@Suite("cmux-tui protocol v8 topology contract")
struct TopologyWireContractTests {
    @Test("canonical snapshot decodes the exact Rust nesting")
    func snapshotContract() throws {
        let snapshot = try JSONDecoder().decode(TopologySnapshot.self, from: Data(snapshotJSON.utf8))
        #expect(snapshot.revision == 7)
        #expect(snapshot.topology.workspaces.first?.screens.first?.panes.first?.tabs.first?.kind == "pty")
        #expect(snapshot.topology.workspaces.first?.screens.first?.layout == .leaf(
            pane: 30,
            paneUUID: PaneID(rawValue: UUID(uuidString: paneUUID)!)
        ))
    }

    @Test("browser endpoint descriptor decodes the cmuxd frame transport")
    func browserEndpointContract() throws {
        let payload = """
        {"id":41,"uuid":"55555555-5555-4555-8555-555555555555","kind":"browser","name":null,"browser_endpoint":{"transport":"cmuxd-png-frame-stream-v1","source":"launched","frontend_projection":"frontend-optional"}}
        """
        let surface = try JSONDecoder().decode(
            CanonicalSurface.self,
            from: Data(payload.utf8)
        )

        #expect(surface.browserEndpoint == CanonicalBrowserEndpoint(
            transport: .cmuxdPNGFrameStreamV1,
            source: .launched,
            frontendProjection: .frontendOptional
        ))
    }

    @Test("browser endpoint without a projection policy remains required")
    func legacyBrowserEndpointFailsClosed() throws {
        let payload = """
        {"id":41,"uuid":"55555555-5555-4555-8555-555555555555","kind":"browser","name":null,"browser_endpoint":{"transport":"cmuxd-png-frame-stream-v1","source":"launched"}}
        """
        let surface = try JSONDecoder().decode(
            CanonicalSurface.self,
            from: Data(payload.utf8)
        )

        #expect(surface.browserEndpoint?.frontendProjection == .required)
    }

    @Test("delta event decodes typed targets and complete replacement")
    func deltaContract() throws {
        let event = try JSONDecoder().decode(BackendServerEvent.self, from: Data(deltaJSON.utf8))
        guard case .delta(let delta) = try event.topologyStreamEvent() else {
            Issue.record("expected topology delta")
            return
        }
        #expect(delta.operation == .workspaceRenamed)
        #expect(delta.baseRevision == 7)
        #expect(delta.revision == 8)
        #expect(delta.targets.workspaces == [WorkspaceID(rawValue: UUID(uuidString: workspaceUUID)!)])
        #expect(delta.replacement.workspaces.first?.name == "renamed")
    }

    @Test("subscription statuses use Rust field names")
    func subscriptionContract() throws {
        let subscribed = try JSONDecoder().decode(
            TopologySubscriptionResponse.self,
            from: Data(subscribedJSON.utf8)
        )
        guard case .subscribed(let subscription) = subscribed else {
            Issue.record("expected subscribed response")
            return
        }
        #expect(subscription.fromRevision == 7)
        #expect(subscription.currentRevision == 9)
        #expect(subscription.replayed == 2)

        let resnapshot = try JSONDecoder().decode(
            TopologySubscriptionResponse.self,
            from: Data(resnapshotJSON.utf8)
        )
        guard case .resnapshotRequired(let required) = resnapshot else {
            Issue.record("expected resnapshot response")
            return
        }
        #expect(required.currentRevision == 9)
        #expect(required.reason == .historyGap)
    }

    @Test("invalid cross-tree references fail closed")
    func invalidReference() {
        let invalid = snapshotJSON.replacingOccurrences(
            of: #""pane_uuid":"33333333-3333-4333-8333-333333333333""#,
            with: #""pane_uuid":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa""#
        )
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TopologySnapshot.self, from: Data(invalid.utf8))
        }
    }

    @Test("layout depth is rejected before unbounded recursive decoding")
    func layoutDepthBudget() {
        var layout = """
        {"type":"leaf","pane":30,"pane_uuid":"\(paneUUID)"}
        """
        for _ in 0 ..< CanonicalLayout.maximumDepth {
            layout = """
            {"type":"split","dir":"right","ratio":0.5,"a":\(layout),"b":{"type":"leaf","pane":30,"pane_uuid":"\(paneUUID)"}}
            """
        }
        let oversized = topologyJSON.replacingOccurrences(
            of: "{\"type\":\"leaf\",\"pane\":30,\"pane_uuid\":\"\(paneUUID)\"}",
            with: layout
        )

        #expect(throws: CanonicalTopologyError.self) {
            try JSONDecoder().decode(CanonicalTopology.self, from: Data(oversized.utf8))
        }
    }

    @Test("workspace count is rejected by an explicit entity budget")
    func workspaceCountBudget() {
        let workspace = """
        {"id":1,"uuid":"\(workspaceUUID)","name":"x","screens":[]}
        """
        let payload = """
        {"workspaces":[\(Array(
            repeating: workspace,
            count: CanonicalTopology.maximumWorkspaces + 1
        ).joined(separator: ","))]}
        """

        #expect(throws: CanonicalTopologyError.self) {
            try JSONDecoder().decode(CanonicalTopology.self, from: Data(payload.utf8))
        }
    }

    private let daemonUUID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let sessionUUID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let workspaceUUID = "11111111-1111-4111-8111-111111111111"
    private let screenUUID = "22222222-2222-4222-8222-222222222222"
    private let paneUUID = "33333333-3333-4333-8333-333333333333"
    private let surfaceUUID = "44444444-4444-4444-8444-444444444444"

    private var topologyJSON: String {
        """
        {"workspaces":[{"id":10,"uuid":"\(workspaceUUID)","name":"one","screens":[{"id":20,"uuid":"\(screenUUID)","name":null,"layout":{"type":"leaf","pane":30,"pane_uuid":"\(paneUUID)"},"panes":[{"id":30,"uuid":"\(paneUUID)","name":null,"tabs":[{"id":40,"uuid":"\(surfaceUUID)","kind":"pty","name":null}]}]}]}]}
        """
    }

    private var snapshotJSON: String {
        """
        {"daemon_instance_id":"\(daemonUUID)","session_id":"\(sessionUUID)","revision":7,"topology":\(topologyJSON)}
        """
    }

    private var deltaJSON: String {
        let replacement = topologyJSON.replacingOccurrences(of: #""name":"one""#, with: #""name":"renamed""#)
        return """
        {"event":"topology-delta","daemon_instance_id":"\(daemonUUID)","session_id":"\(sessionUUID)","base_revision":7,"revision":8,"operation":"workspace-renamed","targets":{"workspaces":["\(workspaceUUID)"]},"replacement":\(replacement)}
        """
    }

    private var subscribedJSON: String {
        """
        {"status":"subscribed","daemon_instance_id":"\(daemonUUID)","session_id":"\(sessionUUID)","from_revision":7,"current_revision":9,"replayed":2}
        """
    }

    private var resnapshotJSON: String {
        """
        {"status":"resnapshot-required","daemon_instance_id":"\(daemonUUID)","session_id":"\(sessionUUID)","current_revision":9,"reason":"history-gap"}
        """
    }
}
