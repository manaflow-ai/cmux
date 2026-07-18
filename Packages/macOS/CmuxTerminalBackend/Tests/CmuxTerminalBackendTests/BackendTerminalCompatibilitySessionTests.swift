import CmuxTerminalBackend
import Foundation
import Testing

@Suite("Dedicated terminal byte-stream compatibility session")
struct BackendTerminalCompatibilitySessionTests {
    @Test("initial event is consumed before the attach response")
    func initialEventBeforeResponse() async throws {
        let fixture = try await attachedFixture()

        #expect(fixture.snapshot.surfaceID == fixture.surfaceID)
        #expect(fixture.snapshot.runtimeEpoch == 41)
        #expect(fixture.snapshot.generation == 1)
        #expect(fixture.snapshot.sequence == 6)
        #expect(fixture.snapshot.replay == Data("snap".utf8))

        var iterator = try await fixture.session.events().makeAsyncIterator()
        #expect(try await iterator.next() == .snapshot(fixture.snapshot))
        await fixture.session.close()
    }

    @Test("a source cursor gap fails closed")
    func cursorGap() async throws {
        let fixture = try await attachedFixture()
        var iterator = try await fixture.session.events().makeAsyncIterator()
        _ = try await iterator.next()

        await fixture.transport.enqueue(try outputEvent(
            fixture: fixture,
            runtimeEpoch: 41,
            generation: 1,
            start: 7,
            next: 8,
            data: Data("x".utf8)
        ))

        await #expect(throws: BackendTerminalCompatibilityError.invalidEvent("output")) {
            _ = try await iterator.next()
        }
        await fixture.transport.waitUntilClosed()
    }

    @Test("the validated event stream has one consumer")
    func eventStreamSingleConsumer() async throws {
        let fixture = try await attachedFixture()
        _ = try await fixture.session.events()

        await #expect(
            throws: BackendTerminalCompatibilityError.eventsAlreadyClaimed
        ) {
            _ = try await fixture.session.events()
        }
        await fixture.session.close()
    }

    @Test("a snapshot cannot retain bytes before sequence zero")
    func malformedSnapshotReplayRange() async {
        await #expect(throws: BackendTerminalCompatibilityError.invalidEvent("vt-state")) {
            _ = try await attachedFixture(
                sequence: 3,
                replay: Data("four".utf8)
            )
        }
    }

    @Test("resize starts a replacement generation at the exact cursor")
    func resizeGeneration() async throws {
        let fixture = try await attachedFixture()
        var iterator = try await fixture.session.events().makeAsyncIterator()
        _ = try await iterator.next()

        let replacementReplay = Data("repl".utf8)
        await fixture.transport.enqueue(try encodedJSON([
            "event": "resized",
            "surface": fixture.surfaceHandle,
            "surface_uuid": fixture.surfaceID.description,
            "runtime_epoch": 41,
            "generation": 2,
            "sequence": 6,
            "cols": 100,
            "rows": 30,
            "replay": replacementReplay.base64EncodedString(),
        ]))

        guard case .replacement(let replacement) = try await iterator.next() else {
            Issue.record("expected replacement replay")
            return
        }
        #expect(replacement.generation == 2)
        #expect(replacement.sequence == 6)
        #expect(replacement.columns == 100)
        #expect(replacement.rows == 30)
        #expect(replacement.replay == replacementReplay)

        await fixture.transport.enqueue(try outputEvent(
            fixture: fixture,
            runtimeEpoch: 41,
            generation: 2,
            start: 6,
            next: 7,
            data: Data("y".utf8)
        ))
        guard case .output(let output) = try await iterator.next() else {
            Issue.record("expected output in replacement generation")
            return
        }
        #expect(output.generation == 2)
        #expect(output.startSequence == 6)
        #expect(output.nextSequence == 7)
        await fixture.session.close()
    }

    @Test("a stale runtime epoch after replacement is rejected")
    func staleRuntimeEpoch() async throws {
        let fixture = try await attachedFixture(runtimeEpoch: 99)
        var iterator = try await fixture.session.events().makeAsyncIterator()
        _ = try await iterator.next()

        await fixture.transport.enqueue(try outputEvent(
            fixture: fixture,
            runtimeEpoch: 41,
            generation: 1,
            start: 6,
            next: 7,
            data: Data("z".utf8)
        ))

        await #expect(throws: BackendTerminalCompatibilityError.invalidEvent("output")) {
            _ = try await iterator.next()
        }
        await fixture.transport.waitUntilClosed()
    }

    @Test("slow output closes only the dedicated connection")
    func slowConsumerIsolation() async throws {
        let independentTransport = ScriptedBackendTransport()
        let independentClient = BackendProtocolClient(transport: independentTransport)
        try await independentClient.connect()

        let fixture = try await attachedFixture(eventCapacity: 1)
        await fixture.transport.enqueue(try outputEvent(
            fixture: fixture,
            runtimeEpoch: 41,
            generation: 1,
            start: 6,
            next: 7,
            data: Data("x".utf8)
        ))
        await fixture.transport.waitUntilClosed()

        let identifyTask = Task { try await independentClient.identify() }
        let request = await independentTransport.nextSent()
        await independentTransport.enqueue(try identifyResponse(
            id: requestID(in: request),
            fixture: fixture
        ))
        #expect(try await identifyTask.value.app == "cmux-tui")
        await independentClient.close()
    }

    @Test("input uses a presentation-bound v9 lease and acknowledges its receipt")
    func input() async throws {
        let fixture = try await attachedFixture()
        let presentationID = PresentationID(rawValue: UUID())
        let leaseID = UUID()
        let inputTask = Task { try await fixture.session.sendInput("hello") }

        let open = try requestObject(await fixture.transport.nextSent())
        #expect(open["cmd"] as? String == "open-presentation")
        let view = try #require(open["view"] as? [String: Any])
        #expect(view["workspace_uuid"] as? String == fixture.workspaceID.description)
        #expect(view["surface_uuid"] as? String == fixture.surfaceID.description)
        await fixture.transport.enqueue(try response(to: open, data: [
            "presentation_id": presentationID.description,
            "generation": 1,
            "client": 7,
            "view": view,
            "zoom": ["pane_uuid": NSNull()],
            "scroll": ["surface_uuid": NSNull(), "offset": 0],
        ]))

        let acquire = try requestObject(await fixture.transport.nextSent())
        #expect(acquire["cmd"] as? String == "acquire-terminal-lease")
        #expect(acquire["kind"] as? String == "input")
        await fixture.transport.enqueue(try response(to: acquire, data: [
            "kind": "input",
            "surface_uuid": fixture.surfaceID.description,
            "presentation_id": presentationID.description,
            "presentation_generation": 1,
            "lease_id": leaseID.uuidString.lowercased(),
            "lease_generation": 1,
            "revocation_sequence": 0,
            "expires_at_ms": 99_999,
            "next_sequence": 1,
            "next_global_input_sequence": 1,
            "migrated_from_legacy": false,
        ]))

        let input = try requestObject(await fixture.transport.nextSent())
        #expect(input["cmd"] as? String == "terminal-input")
        let inputValue = try #require(input["input"] as? [String: Any])
        #expect(inputValue["type"] as? String == "text")
        #expect(inputValue["text"] as? String == "hello")
        #expect(inputValue["paste"] as? Bool == false)
        let requestID = try #require(input["request_id"] as? String)
        await fixture.transport.enqueue(try response(to: input, data: [
            "request_id": requestID,
            "status": "applied",
            "kind": "input",
            "sequence": 1,
            "ordered_input_sequence": 1,
            "lease_generation": 1,
            "replayed": false,
            "encoded_bytes": 5,
            "lease_revoked": false,
        ]))

        let acknowledge = try requestObject(await fixture.transport.nextSent())
        #expect(acknowledge["cmd"] as? String == "acknowledge-terminal-request")
        #expect(acknowledge["request_id"] as? String == requestID)
        await fixture.transport.enqueue(try response(to: acknowledge, data: [
            "request_id": requestID,
            "acknowledged": true,
        ]))
        try await inputTask.value
    }

    private struct Fixture {
        let session: BackendTerminalCompatibilitySession
        let transport: ScriptedBackendTransport
        let snapshot: BackendTerminalCompatibilitySnapshot
        let authority: BackendAuthority
        let registrationIdentity: BackendClientRegistrationIdentity
        let workspaceID: WorkspaceID
        let surfaceID: SurfaceID
        let surfaceHandle: UInt64
        let processID: UInt32
    }

    private func attachedFixture(
        eventCapacity: Int = BackendTerminalCompatibilitySession.defaultEventCapacity,
        runtimeEpoch: UInt64 = 41,
        sequence: UInt64 = 6,
        replay: Data = Data("snap".utf8)
    ) async throws -> Fixture {
        let transport = ScriptedBackendTransport()
        let authority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: SessionID(rawValue: UUID())
        )
        let registrationIdentity = try #require(BackendClientRegistrationIdentity(
            clientUUID: UUID(),
            processInstanceUUID: UUID()
        ))
        let workspaceID = WorkspaceID(rawValue: UUID())
        let screenID = ScreenID(rawValue: UUID())
        let paneID = PaneID(rawValue: UUID())
        let surfaceID = SurfaceID(rawValue: UUID())
        let surfaceHandle: UInt64 = 40
        let processID: UInt32 = 42
        let peerIdentity = BackendPeerIdentity(
            processID: processID,
            userID: 501,
            auditToken: BackendAuditToken(
                word0: 1, word1: 2, word2: 3, word3: 4,
                word4: 5, word5: 6, word6: 7, word7: 8
            )
        )
        let session = BackendTerminalCompatibilitySession(
            transport: transport,
            expectation: BackendCanonicalSessionExpectation(
                session: "app-session",
                authority: authority,
                processID: processID,
                peerIdentity: peerIdentity
            ),
            registrationIdentity: registrationIdentity,
            eventCapacity: eventCapacity
        )
        let attachTask = Task { try await session.attach(surfaceID: surfaceID) }

        let identify = try requestObject(await transport.nextSent())
        #expect(identify["cmd"] as? String == "identify")
        await transport.enqueue(try identifyResponse(
            id: try requestID(in: JSONSerialization.data(withJSONObject: identify)),
            authority: authority,
            processID: processID
        ))

        let registration = try requestObject(await transport.nextSent())
        #expect(registration["cmd"] as? String == "register-client")
        #expect(registration["protocol_min"] as? NSNumber == 9)
        #expect(registration["protocol_max"] as? NSNumber == 9)
        await transport.enqueue(try response(to: registration, data: [
            "protocol": 9,
            "connection_id": UUID().uuidString.lowercased(),
            "client_uuid": registrationIdentity.clientUUID.uuidString.lowercased(),
            "process_instance_uuid": registrationIdentity.processInstanceUUID.uuidString.lowercased(),
            "client_kind": "swift-shell",
            "role": "trusted-frontend",
            "topology_lease_id": UUID().uuidString.lowercased(),
            "topology_lease_generation": 1,
        ]))

        let topology = try requestObject(await transport.nextSent())
        #expect(topology["cmd"] as? String == "topology-snapshot")
        await transport.enqueue(try response(to: topology, data: [
            "daemon_instance_id": authority.daemonInstanceID.description,
            "session_id": authority.sessionID.description,
            "revision": 1,
            "topology": [
                "workspaces": [[
                    "id": 10,
                    "uuid": workspaceID.description,
                    "name": "one",
                    "screens": [[
                        "id": 20,
                        "uuid": screenID.description,
                        "name": NSNull(),
                        "layout": [
                            "type": "leaf",
                            "pane": 30,
                            "pane_uuid": paneID.description,
                        ],
                        "panes": [[
                            "id": 30,
                            "uuid": paneID.description,
                            "name": NSNull(),
                            "tabs": [[
                                "id": surfaceHandle,
                                "uuid": surfaceID.description,
                                "kind": "pty",
                                "name": NSNull(),
                            ]],
                        ]],
                    ]],
                ]],
            ],
        ]))

        let attach = try requestObject(await transport.nextSent())
        #expect(attach["cmd"] as? String == "attach-surface")
        #expect(try uint64(attach, "surface") == surfaceHandle)
        #expect(attach["mode"] as? String == "compatibility")
        await transport.enqueue(try encodedJSON([
            "event": "vt-state",
            "surface": surfaceHandle,
            "surface_uuid": surfaceID.description,
            "runtime_epoch": runtimeEpoch,
            "generation": 1,
            "sequence": sequence,
            "fidelity": BackendTerminalCompatibilitySnapshot.fidelity,
            "cols": 80,
            "rows": 24,
            "data": replay.base64EncodedString(),
            "colors": [:] as [String: Any],
        ]))
        await transport.enqueue(try response(to: attach, data: [:]))
        let snapshot = try await attachTask.value
        return Fixture(
            session: session,
            transport: transport,
            snapshot: snapshot,
            authority: authority,
            registrationIdentity: registrationIdentity,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            surfaceHandle: surfaceHandle,
            processID: processID
        )
    }

    private func identifyResponse(
        id: UInt64,
        fixture: Fixture
    ) throws -> Data {
        try identifyResponse(
            id: id,
            authority: fixture.authority,
            processID: fixture.processID
        )
    }

    private func identifyResponse(
        id: UInt64,
        authority: BackendAuthority,
        processID: UInt32
    ) throws -> Data {
        let capabilities = Set([
            BackendTerminalCompatibilitySession.capability,
            "canonical-topology-snapshot-v1",
            "presentation-registry-v1",
            "stable-entity-uuid-v1",
        ]).union(BackendHandshakePolicy.terminalControlV9Capabilities)
        return try encodedJSON([
            "id": id,
            "ok": true,
            "data": [
                "app": "cmux-tui",
                "version": "0.1.0",
                "protocol": 9,
                "protocol_min": 8,
                "protocol_max": 9,
                "capabilities": capabilities.sorted(),
                "session": "app-session",
                "session_id": authority.sessionID.description,
                "daemon_instance_id": authority.daemonInstanceID.description,
                "topology_revision": 1,
                "canonical_topology_revision": 1,
                "pid": processID,
            ],
        ])
    }

    private func outputEvent(
        fixture: Fixture,
        runtimeEpoch: UInt64,
        generation: UInt64,
        start: UInt64,
        next: UInt64,
        data: Data
    ) throws -> Data {
        try encodedJSON([
            "event": "output",
            "surface": fixture.surfaceHandle,
            "surface_uuid": fixture.surfaceID.description,
            "runtime_epoch": runtimeEpoch,
            "generation": generation,
            "start_sequence": start,
            "next_sequence": next,
            "data": data.base64EncodedString(),
        ])
    }

    private func requestObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func response(to request: [String: Any], data: [String: Any]) throws -> Data {
        try encodedJSON([
            "id": try #require(request["id"] as? NSNumber).uint64Value,
            "ok": true,
            "data": data,
        ])
    }

    private func uint64(_ object: [String: Any], _ key: String) throws -> UInt64 {
        try #require(object[key] as? NSNumber).uint64Value
    }
}
