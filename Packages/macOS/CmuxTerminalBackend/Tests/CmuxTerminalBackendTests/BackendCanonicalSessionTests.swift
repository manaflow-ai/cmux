import CmuxTerminalBackend
import Foundation
import Testing

@Suite("Canonical backend session")
struct BackendCanonicalSessionTests {
    @Test("snapshot fence resumes into contiguous topology deltas")
    func snapshotThenDelta() async throws {
        let transport = ScriptedBackendTransport()
        let authority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: SessionID(rawValue: UUID())
        )
        let session = BackendCanonicalSession(
            transport: transport,
            expectation: BackendCanonicalSessionExpectation(
                session: "app-session",
                authority: authority,
                processID: 4321
            )
        )
        let events = await session.events()
        var iterator = events.makeAsyncIterator()

        let connectTask = Task { try await session.connect() }
        try await completeHandshake(
            transport: transport,
            authority: authority,
            session: "app-session",
            processID: 4321
        )
        let initial = try await connectTask.value
        #expect(initial.revision == 0)
        guard case .snapshot(let published)? = await iterator.next() else {
            Issue.record("expected initial snapshot")
            return
        }
        #expect(published == initial)

        let workspaceID = WorkspaceID(rawValue: UUID())
        await transport.enqueue(try encodedJSON([
            "event": "renderer-worker-changed",
            "workspace_uuid": workspaceID.description,
            "prior_renderer_epoch": 4,
            "prior_process_id": 4000,
            "renderer_epoch": 5,
            "pid": 4321,
            "effective_user_id": 501,
            "scene_capabilities": 3,
            "state": "ready",
            "restart_count": 1,
            "retry_after_milliseconds": NSNull(),
            "reason": NSNull(),
        ]))
        guard case .rendererWorkerChanged(let worker)? = await iterator.next() else {
            Issue.record("expected renderer worker transition")
            return
        }
        #expect(worker.workspaceID == workspaceID)
        #expect(worker.priorRendererEpoch == 4)
        #expect(worker.rendererEpoch == 5)
        #expect(worker.processID == 4321)
        #expect(worker.state == .ready)

        let presentationID = PresentationID(rawValue: UUID())
        let terminalID = SurfaceID(rawValue: UUID())
        await transport.enqueue(try encodedJSON([
            "event": "renderer-presentation-ready",
            "workspace_uuid": workspaceID.description,
            "renderer_epoch": 5,
            "worker_pid": 4321,
            "worker_effective_user_id": 501,
            "terminal_id": terminalID.description,
            "terminal_epoch": 2,
            "presentation_id": presentationID.description,
            "presentation_generation": 8,
            "canonical_sequence": 21,
            "presentation_sequence": 3,
            "columns": 120,
            "rows": 40,
            "cell_width": 18,
            "cell_height": 36,
            "padding": ["top": 10, "right": 20, "bottom": 10, "left": 20],
        ]))
        guard case .rendererPresentationReady(let ready)? = await iterator.next() else {
            Issue.record("expected renderer presentation metrics")
            return
        }
        #expect(ready.presentationID == presentationID)
        #expect(ready.terminalID == terminalID)
        #expect(ready.rendererEpoch == 5)
        #expect(ready.presentationGeneration == 8)
        #expect(ready.cellWidth == 18)
        #expect(ready.padding.left == 20)

        let surfaceID = SurfaceID(rawValue: UUID())
        let delta = try topologyDelta(authority: authority, surfaceID: surfaceID)
        await transport.enqueue(try topologyEvent(delta))
        guard case .delta(let publishedDelta)? = await iterator.next() else {
            Issue.record("expected contiguous topology delta")
            return
        }
        #expect(publishedDelta == delta)
        #expect(await session.currentSnapshot()?.revision == 1)
        #expect(await session.surface(handle: 4)?.uuid == surfaceID)

        await session.close()
    }

    @Test("identity mismatch fails before topology is requested")
    func identityMismatchFailsClosed() async throws {
        let transport = ScriptedBackendTransport()
        let authority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: SessionID(rawValue: UUID())
        )
        let session = BackendCanonicalSession(
            transport: transport,
            expectation: BackendCanonicalSessionExpectation(session: "expected")
        )
        let task = Task { try await session.connect() }
        let identify = try requestObject(await transport.nextSent())
        await transport.enqueue(try identifyResponse(
            request: identify,
            authority: authority,
            session: "other",
            processID: 99
        ))

        await #expect(throws: BackendCanonicalSessionError.self) {
            try await task.value
        }
        #expect(await transport.sentCount() == 0)
        await transport.waitUntilClosed()
    }

    @Test("replacement socket peer fails before any protocol request")
    func replacementSocketPeerFailsClosed() async throws {
        let transport = ScriptedBackendTransport()
        let trustedPeer = BackendPeerIdentity(
            processID: 4321,
            userID: 501,
            auditToken: BackendAuditToken(
                word0: 11, word1: 12, word2: 13, word3: 14,
                word4: 15, word5: 16, word6: 17, word7: 18
            )
        )
        let session = BackendCanonicalSession(
            transport: transport,
            expectation: BackendCanonicalSessionExpectation(
                session: "app-session",
                processID: trustedPeer.processID,
                peerIdentity: trustedPeer
            )
        )

        await #expect(
            throws: BackendCanonicalSessionError.unexpectedPeerIdentity(
                expected: trustedPeer,
                actual: BackendPeerIdentity(
                    processID: 42,
                    userID: 501,
                    auditToken: BackendAuditToken(
                        word0: 1, word1: 2, word2: 3, word3: 4,
                        word4: 5, word5: 6, word6: 7, word7: 8
                    )
                )
            )
        ) {
            try await session.connect()
        }
        #expect(await transport.sentCount() == 0)
        await transport.waitUntilClosed()
    }

    private func completeHandshake(
        transport: ScriptedBackendTransport,
        authority: BackendAuthority,
        session: String,
        processID: UInt32
    ) async throws {
        let identify = try requestObject(await transport.nextSent())
        #expect(identify["cmd"] as? String == "identify")
        await transport.enqueue(try identifyResponse(
            request: identify,
            authority: authority,
            session: session,
            processID: processID
        ))

        let snapshot = try requestObject(await transport.nextSent())
        #expect(snapshot["cmd"] as? String == "topology-snapshot")
        await transport.enqueue(try response(
            to: snapshot,
            data: [
                "daemon_instance_id": authority.daemonInstanceID.description,
                "session_id": authority.sessionID.description,
                "revision": 0,
                "topology": ["workspaces": []],
            ]
        ))

        let subscribe = try requestObject(await transport.nextSent())
        #expect(subscribe["cmd"] as? String == "subscribe-topology")
        #expect(try uint64(subscribe, "revision") == 0)
        await transport.enqueue(try response(
            to: subscribe,
            data: [
                "status": "subscribed",
                "daemon_instance_id": authority.daemonInstanceID.description,
                "session_id": authority.sessionID.description,
                "from_revision": 0,
                "current_revision": 0,
                "replayed": 0,
            ]
        ))
    }

    private func identifyResponse(
        request: [String: Any],
        authority: BackendAuthority,
        session: String,
        processID: UInt32
    ) throws -> Data {
        try response(
            to: request,
            data: [
                "app": "cmux-tui",
                "version": "0.1.0",
                "protocol": 8,
                "protocol_min": 8,
                "protocol_max": 8,
                "capabilities": [
                    "canonical-topology-snapshot-v1",
                    "durable-session-identity-v1",
                    "presentation-registry-v1",
                    "stable-entity-uuid-v1",
                    "topology-resume-v1",
                ],
                "session": session,
                "session_id": authority.sessionID.description,
                "daemon_instance_id": authority.daemonInstanceID.description,
                "topology_revision": 0,
                "canonical_topology_revision": 0,
                "pid": processID,
            ]
        )
    }

    private func topologyDelta(
        authority: BackendAuthority,
        surfaceID: SurfaceID
    ) throws -> TopologyDelta {
        let workspaceID = WorkspaceID(rawValue: UUID())
        let screenID = ScreenID(rawValue: UUID())
        let paneID = PaneID(rawValue: UUID())
        let surface = CanonicalSurface(id: 4, uuid: surfaceID, kind: "pty", name: nil)
        let pane = CanonicalPane(id: 3, uuid: paneID, name: nil, tabs: [surface])
        let screen = CanonicalScreen(
            id: 2,
            uuid: screenID,
            name: nil,
            layout: .leaf(pane: 3, paneUUID: paneID),
            panes: [pane]
        )
        let workspace = CanonicalWorkspace(
            id: 1,
            uuid: workspaceID,
            name: "agents",
            screens: [screen]
        )
        return TopologyDelta(
            authority: authority,
            baseRevision: 0,
            revision: 1,
            operation: .workspaceCreated,
            targets: try TopologyTargets(
                workspaces: [workspaceID],
                screens: [screenID],
                panes: [paneID],
                surfaces: [surfaceID]
            ),
            replacement: try CanonicalTopology(workspaces: [workspace])
        )
    }

    private func topologyEvent(_ delta: TopologyDelta) throws -> Data {
        let data = try JSONEncoder().encode(delta)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["event"] = "topology-delta"
        return try encodedJSON(object)
    }

    private func requestObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func response(to request: [String: Any], data: [String: Any]) throws -> Data {
        try encodedJSON([
            "id": try uint64(request, "id"),
            "ok": true,
            "data": data,
        ])
    }

    private func uint64(_ object: [String: Any], _ key: String) throws -> UInt64 {
        try #require(object[key] as? NSNumber).uint64Value
    }
}
