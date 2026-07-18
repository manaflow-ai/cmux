import CmuxTerminalBackend
import Foundation
import Testing

@Suite("Bounded backend protocol client")
struct BackendProtocolClientTests {
    @Test("event interleaves with a correlated response")
    func interleavedEventAndResponse() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport, eventCapacity: 4)
        try await client.connect()
        let events = await client.events()

        let identifyTask = Task { try await client.identify() }
        let request = await transport.nextSent()
        let id = try requestID(in: request)
        await transport.enqueue(try encodedJSON([
            "event": "topology-delta",
            "revision": 1,
        ]))
        await transport.enqueue(try identifyResponse(id: id))

        let response = try await identifyTask.value
        #expect(response.app == "cmux-tui")
        var iterator = events.makeAsyncIterator()
        let event = try await iterator.next()
        #expect(event?.name == "topology-delta")
        #expect(event?.fields["revision"] == .integer(1))
        await client.close()
    }

    @Test("local event overflow closes instead of hiding a gap")
    func eventOverflowCloses() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport, eventCapacity: 1)
        try await client.connect()
        let events = await client.events()

        await transport.enqueue(try encodedJSON(["event": "first"]))
        await transport.enqueue(try encodedJSON(["event": "second"]))
        await transport.waitUntilClosed()

        var iterator = events.makeAsyncIterator()
        let retained = try await iterator.next()
        #expect(retained?.name == "first")
        do {
            let postGap = try await iterator.next()
            Issue.record("unexpected post-gap event: \(String(describing: postGap?.name))")
        } catch let error as BackendProtocolError {
            #expect(error == .eventBufferOverflow(capacity: 1))
        }
    }

    @Test("a pre-cancelled call writes no request and leaves the client connected")
    func preCancelledCallWritesNothing() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.identify()
        }

        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        #expect(await transport.sentCount() == 0)

        let valid = Task { try await client.identify() }
        let request = await transport.nextSent()
        await transport.enqueue(try identifyResponse(id: requestID(in: request)))
        #expect(try await valid.value.app == "cmux-tui")
        await client.close()
    }

    @Test("mixed event and response envelope closes instead of stranding a request")
    func mixedEnvelopeCloses() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let task = Task { try await client.identify() }
        let request = await transport.nextSent()
        let id = try requestID(in: request)

        await transport.enqueue(try encodedJSON([
            "id": id,
            "event": "topology-delta",
            "ok": true,
            "data": ["revision": 1],
        ]))

        await #expect(throws: BackendProtocolError.malformedMessage) {
            try await task.value
        }
        await transport.waitUntilClosed()
    }

    @Test("topology subscription sends the exact v8 resume fence")
    func topologySubscriptionRequest() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let authority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: SessionID(rawValue: UUID())
        )

        let task = Task {
            try await client.subscribeTopology(authority: authority, revision: UInt64.max)
        }
        let request = await transport.nextSent()
        let object = try #require(try JSONSerialization.jsonObject(with: request) as? [String: Any])
        let id = try #require(object["id"] as? NSNumber).uint64Value
        #expect(object["cmd"] as? String == "subscribe-topology")
        #expect(object["daemon_instance_id"] as? String == authority.daemonInstanceID.description)
        #expect(object["session_id"] as? String == authority.sessionID.description)
        #expect(try #require(object["revision"] as? NSNumber).uint64Value == UInt64.max)
        await transport.enqueue(try encodedJSON([
            "id": id,
            "ok": true,
            "data": [
                "status": "resnapshot-required",
                "daemon_instance_id": authority.daemonInstanceID.description,
                "session_id": authority.sessionID.description,
                "current_revision": 9,
                "reason": "revision-ahead",
            ],
        ]))

        guard case .resnapshotRequired(let response) = try await task.value else {
            Issue.record("expected resnapshot response")
            return
        }
        #expect(response.reason == .revisionAhead)
        await client.close()
    }

    @Test("presentation commands use UUID-only connection-local state")
    func presentationCommands() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let workspace = WorkspaceID(rawValue: UUID())
        let screen = ScreenID(rawValue: UUID())
        let pane = PaneID(rawValue: UUID())
        let surface = SurfaceID(rawValue: UUID())
        let presentationID = PresentationID(rawValue: UUID())
        let view = BackendPresentationView(
            workspaceID: workspace,
            screenID: screen,
            paneID: pane,
            surfaceID: surface
        )

        let openTask = Task { try await client.openPresentation(view: view) }
        let openData = await transport.nextSent()
        let openRequest = try #require(
            try JSONSerialization.jsonObject(with: openData) as? [String: Any]
        )
        #expect(openRequest["cmd"] as? String == "open-presentation")
        let openView = try #require(openRequest["view"] as? [String: Any])
        #expect(openView["workspace_uuid"] as? String == workspace.description)
        #expect(openView["screen_uuid"] as? String == screen.description)
        #expect(openView["pane_uuid"] as? String == pane.description)
        #expect(openView["surface_uuid"] as? String == surface.description)
        await transport.enqueue(try presentationResponse(
            request: openRequest,
            presentationID: presentationID,
            generation: 1,
            view: view,
            zoomPane: nil
        ))
        #expect(try await openTask.value.generation == 1)

        let activationTask = Task {
            try await client.activateTerminalPresentation(
                id: presentationID,
                expectedGeneration: 1
            )
        }
        let activationData = await transport.nextSent()
        let activationRequest = try #require(
            try JSONSerialization.jsonObject(with: activationData) as? [String: Any]
        )
        #expect(activationRequest["cmd"] as? String == "activate-terminal-presentation")
        #expect(activationRequest["presentation_id"] as? String == presentationID.description)
        #expect(
            try #require(activationRequest["expected_generation"] as? NSNumber).uint64Value
                == 1
        )
        await transport.enqueue(try encodedJSON([
            "id": try #require(activationRequest["id"] as? NSNumber).uint64Value,
            "ok": true,
            "data": [
                "presentation_id": presentationID.description,
                "presentation_generation": 1,
                "surface_uuid": surface.description,
            ],
        ]))
        let activation = try await activationTask.value
        #expect(activation.presentationID == presentationID)
        #expect(activation.presentationGeneration == 1)
        #expect(activation.surfaceID == surface)

        let updateTask = Task {
            try await client.updatePresentation(
                id: presentationID,
                expectedGeneration: 1,
                zoom: BackendPresentationZoom(paneID: pane)
            )
        }
        let updateData = await transport.nextSent()
        let updateRequest = try #require(
            try JSONSerialization.jsonObject(with: updateData) as? [String: Any]
        )
        #expect(updateRequest["cmd"] as? String == "update-presentation")
        #expect(updateRequest["view"] == nil)
        #expect(try #require(updateRequest["expected_generation"] as? NSNumber).uint64Value == 1)
        #expect(
            (try #require(updateRequest["zoom"] as? [String: Any]))["pane_uuid"] as? String
                == pane.description
        )
        await transport.enqueue(try presentationResponse(
            request: updateRequest,
            presentationID: presentationID,
            generation: 2,
            view: view,
            zoomPane: pane
        ))
        #expect(try await updateTask.value.generation == 2)

        let closeTask = Task { try await client.closePresentation(id: presentationID) }
        let closeData = await transport.nextSent()
        let closeRequest = try #require(
            try JSONSerialization.jsonObject(with: closeData) as? [String: Any]
        )
        #expect(closeRequest["cmd"] as? String == "close-presentation")
        #expect(closeRequest["presentation_id"] as? String == presentationID.description)
        await transport.enqueue(try encodedJSON([
            "id": try #require(closeRequest["id"] as? NSNumber).uint64Value,
            "ok": true,
            "data": [:] as [String: Any],
        ]))
        try await closeTask.value
        await client.close()
    }

    @Test("cancelling a request closes the ambiguous connection")
    func cancellationClosesConnection() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let task = Task { try await client.identify() }
        _ = await transport.nextSent()

        task.cancel()
        await transport.waitUntilClosed()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("cancellation wins when a response reaches the transport concurrently")
    func cancellationWinsResponseRace() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let task = Task { try await client.identify() }
        let request = await transport.nextSent()
        let response = try identifyResponse(id: requestID(in: request))
        await transport.runBeforeNextReceiveReturns {
            task.cancel()
        }

        await transport.enqueue(response)
        await transport.waitUntilClosed()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("ambiguous send failure closes every pending request")
    func sendFailureClosesConnection() async {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        do {
            try await client.connect()
        } catch {
            Issue.record("unexpected connect failure: \(error)")
            return
        }
        await transport.injectNextSendFailure()
        let task = Task { try await client.identify() }
        await transport.waitUntilClosed()
        await #expect(throws: BackendProtocolError.connectionClosed) {
            try await task.value
        }
    }

    private func identifyResponse(id: UInt64) throws -> Data {
        try encodedJSON([
            "id": id,
            "ok": true,
            "data": [
                "app": "cmux-tui",
                "version": "0.1.0",
                "protocol": 8,
                "protocol_min": 8,
                "protocol_max": 8,
                "capabilities": ["stable-identities"],
                "session": "main",
                "session_id": UUID().uuidString,
                "daemon_instance_id": UUID().uuidString,
                "topology_revision": 0,
                "pid": 123,
            ],
        ])
    }

    private func presentationResponse(
        request: [String: Any],
        presentationID: PresentationID,
        generation: UInt64,
        view: BackendPresentationView,
        zoomPane: PaneID?
    ) throws -> Data {
        let viewObject: [String: Any] = [
            "workspace_uuid": view.workspaceID.map { $0.description } ?? NSNull(),
            "screen_uuid": view.screenID.map { $0.description } ?? NSNull(),
            "pane_uuid": view.paneID.map { $0.description } ?? NSNull(),
            "surface_uuid": view.surfaceID.map { $0.description } ?? NSNull(),
        ]
        let zoomObject: [String: Any] = [
            "pane_uuid": zoomPane.map { $0.description } ?? NSNull(),
        ]
        let scrollObject: [String: Any] = [
            "surface_uuid": NSNull(),
            "offset": 0,
        ]
        let data: [String: Any] = [
            "presentation_id": presentationID.description,
            "generation": generation,
            "client": 7,
            "view": viewObject,
            "zoom": zoomObject,
            "scroll": scrollObject,
        ]
        let response: [String: Any] = [
            "id": try #require(request["id"] as? NSNumber).uint64Value,
            "ok": true,
            "data": data,
        ]
        return try encodedJSON(response)
    }
}
