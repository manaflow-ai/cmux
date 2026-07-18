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

    @Test("synthesized snapshot bytes are independent from the raw-output cursor")
    func snapshotReplayMayExceedSequence() async throws {
        let replay = Data("snapshot".utf8)
        let fixture = try await attachedFixture(sequence: 3, replay: replay)

        #expect(fixture.snapshot.sequence == 3)
        #expect(fixture.snapshot.replay == replay)
        await fixture.session.close()
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

    @Test("input uses the canonical owner's text-only delegation and acknowledges its receipt")
    func delegatedInput() async throws {
        let fixture = try await attachedFixture()
        let input = try await sendAndAcknowledgeInput(
            "hello",
            orderedInputSequence: 71,
            fixture: fixture
        )

        #expect(input["cmd"] as? String == "terminal-delegated-input")
        let inputValue = try #require(input["input"] as? [String: Any])
        #expect(inputValue["type"] as? String == "text")
        #expect(inputValue["text"] as? String == "hello")
        #expect(inputValue["paste"] as? Bool == false)
        #expect(try uint64(input, "sequence") == 1)
        #expect(input["presentation_id"] == nil)
        #expect(input["lease_id"] == nil)

        let calls = await fixture.inputAuthority.authorizationCalls()
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.surfaceID == fixture.surfaceID)
        #expect(call.delegateIdentity == fixture.registrationIdentity)
        #expect(call.replacing == nil)

        await fixture.session.close()
        let revocations = await fixture.inputAuthority.revokedDelegations()
        #expect(revocations.count == 1)
        let revoked = try #require(revocations.first)
        #expect(
            revoked.delegateClientUUID
                == fixture.registrationIdentity.clientUUID
        )
    }

    @Test("one delegation advances its lane sequence across inputs")
    func delegatedInputSequence() async throws {
        let fixture = try await attachedFixture()
        let first = try await sendAndAcknowledgeInput(
            "one",
            orderedInputSequence: 1,
            fixture: fixture
        )
        let second = try await sendAndAcknowledgeInput(
            "two",
            orderedInputSequence: 2,
            fixture: fixture
        )

        #expect(try uint64(first, "sequence") == 1)
        #expect(try uint64(second, "sequence") == 2)
        #expect(first["delegation_id"] as? String == second["delegation_id"] as? String)
        let calls = await fixture.inputAuthority.authorizationCalls()
        #expect(calls.count == 2)
        #expect(calls.last?.replacing != nil)
        await fixture.session.close()
    }

    @Test("concurrent phone input is serialized into one delegate-local sequence")
    func concurrentDelegatedInputSequence() async throws {
        let fixture = try await attachedFixture()
        let firstTask = Task { try await fixture.session.sendInput("one") }
        let first = try requestObject(await fixture.transport.nextSent())
        #expect(try uint64(first, "sequence") == 1)

        let secondTask = Task { try await fixture.session.sendInput("two") }
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(await fixture.transport.sentCount() == 0)

        try await respondToInput(
            first,
            orderedInputSequence: 11,
            textByteCount: 3,
            fixture: fixture
        )
        let second = try requestObject(await fixture.transport.nextSent())
        #expect(try uint64(second, "sequence") == 2)
        #expect(first["delegation_id"] as? String == second["delegation_id"] as? String)
        try await respondToInput(
            second,
            orderedInputSequence: 12,
            textByteCount: 3,
            fixture: fixture
        )
        try await firstTask.value
        try await secondTask.value
        await fixture.session.close()
    }

    @Test("a deadline refresh replaces the delegation before sending")
    func delegatedInputRefresh() async throws {
        let fixture = try await attachedFixture()
        let first = try await sendAndAcknowledgeInput(
            "before",
            orderedInputSequence: 8,
            fixture: fixture
        )
        await fixture.inputAuthority.replaceOnNextAuthorization(nextSequence: 7)
        let second = try await sendAndAcknowledgeInput(
            "after",
            orderedInputSequence: 9,
            fixture: fixture
        )

        #expect(first["delegation_id"] as? String != second["delegation_id"] as? String)
        #expect(try uint64(first, "sequence") == 1)
        #expect(try uint64(second, "sequence") == 7)
        let calls = await fixture.inputAuthority.authorizationCalls()
        let old = try #require(calls.last?.replacing)
        let refreshRevocations = await fixture.inputAuthority.revokedDelegations()
        #expect(refreshRevocations == [old])

        await fixture.session.close()
        let finalRevocations = await fixture.inputAuthority.revokedDelegations()
        #expect(finalRevocations.count == 2)
        let firstRevocation = try #require(finalRevocations.first)
        let lastRevocation = try #require(finalRevocations.last)
        #expect(firstRevocation != lastRevocation)
    }

    @Test("an in-place same-generation authority mutation fails closed")
    func rejectsMutatedSameGenerationDelegation() async throws {
        let fixture = try await attachedFixture()
        _ = try await sendAndAcknowledgeInput(
            "before",
            orderedInputSequence: 8,
            fixture: fixture
        )
        let old = try #require((await fixture.inputAuthority.issuedDelegations()).first)
        await fixture.inputAuthority.mutateSameGenerationOnNextAuthorization()

        await #expect(throws: BackendProtocolError.malformedMessage) {
            try await fixture.session.sendInput("blocked")
        }
        await fixture.transport.waitUntilClosed()

        let calls = await fixture.inputAuthority.authorizationCalls()
        let replacing = try #require(calls.last?.replacing)
        #expect(replacing == old)
        let revoked = try #require(
            (await fixture.inputAuthority.revokedDelegations()).last
        )
        #expect(revoked.delegationID == old.delegationID)
        #expect(revoked.delegationGeneration == old.delegationGeneration)
        #expect(revoked != old)
    }

    @Test("a delegation broader than text fails closed and is revoked")
    func rejectsBroadInputDelegation() async throws {
        let fixture = try await attachedFixture()
        await fixture.inputAuthority.useScopesOnNextAuthorization(["text", "key"])

        await #expect(throws: BackendProtocolError.malformedMessage) {
            try await fixture.session.sendInput("blocked")
        }
        await fixture.transport.waitUntilClosed()
        let revoked = await fixture.inputAuthority.revokedDelegations()
        #expect(revoked.count == 1)
        #expect(revoked.first?.scopes == [.text, .key])
    }

    private struct Fixture {
        let session: BackendTerminalCompatibilitySession
        let transport: ScriptedBackendTransport
        let snapshot: BackendTerminalCompatibilitySnapshot
        let authority: BackendAuthority
        let registrationIdentity: BackendClientRegistrationIdentity
        let inputAuthority: RecordingCompatibilityInputAuthority
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
        let inputAuthority = RecordingCompatibilityInputAuthority()
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
            inputAuthority: inputAuthority,
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
        #expect(registration["client_kind"] as? String == "mobile-compatibility")
        await transport.enqueue(try response(to: registration, data: [
            "protocol": 9,
            "connection_id": UUID().uuidString.lowercased(),
            "client_uuid": registrationIdentity.clientUUID.uuidString.lowercased(),
            "process_instance_uuid": registrationIdentity.processInstanceUUID.uuidString.lowercased(),
            "client_kind": "mobile-compatibility",
            "role": "trusted-input-delegate",
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
        #expect(
            try uint64(attach, "replay_max_bytes")
                == UInt64(BackendTerminalCompatibilitySession.maximumReplayBytes)
        )
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
            inputAuthority: inputAuthority,
            surfaceID: surfaceID,
            surfaceHandle: surfaceHandle,
            processID: processID
        )
    }

    private func sendAndAcknowledgeInput(
        _ text: String,
        orderedInputSequence: UInt64,
        fixture: Fixture
    ) async throws -> [String: Any] {
        let inputTask = Task { try await fixture.session.sendInput(text) }
        let input = try requestObject(await fixture.transport.nextSent())
        #expect(input["cmd"] as? String == "terminal-delegated-input")
        try await respondToInput(
            input,
            orderedInputSequence: orderedInputSequence,
            textByteCount: text.utf8.count,
            fixture: fixture
        )
        try await inputTask.value
        return input
    }

    private func respondToInput(
        _ input: [String: Any],
        orderedInputSequence: UInt64,
        textByteCount: Int,
        fixture: Fixture
    ) async throws {
        let requestID = try #require(input["request_id"] as? String)
        let sequence = try uint64(input, "sequence")
        await fixture.transport.enqueue(try response(to: input, data: [
            "request_id": requestID,
            "status": "applied",
            "kind": "input",
            "sequence": sequence,
            "ordered_input_sequence": orderedInputSequence,
            "lease_generation": 41,
            "replayed": false,
            "encoded_bytes": textByteCount,
            "lease_revoked": false,
        ]))

        let acknowledge = try requestObject(await fixture.transport.nextSent())
        #expect(acknowledge["cmd"] as? String == "acknowledge-terminal-request")
        #expect(acknowledge["request_id"] as? String == requestID)
        await fixture.transport.enqueue(try response(to: acknowledge, data: [
            "request_id": requestID,
            "acknowledged": true,
        ]))
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

private actor RecordingCompatibilityInputAuthority:
    BackendTerminalCompatibilityInputAuthority {
    struct AuthorizationCall: Equatable, Sendable {
        let surfaceID: SurfaceID
        let delegateIdentity: BackendClientRegistrationIdentity
        let replacing: BackendTerminalInputDelegation?
    }

    private var calls: [AuthorizationCall] = []
    private var revocations: [BackendTerminalInputDelegation] = []
    private var replaceNext = false
    private var mutateSameGenerationNext = false
    private var nextGeneration: UInt64 = 1
    private var nextScopes = ["text"]
    private var nextDelegationSequence: UInt64 = 1
    private var issued: [BackendTerminalInputDelegation] = []

    func authorizeTerminalCompatibilityInput(
        surfaceID: SurfaceID,
        delegateIdentity: BackendClientRegistrationIdentity,
        replacing: BackendTerminalInputDelegation?
    ) async throws -> BackendTerminalInputDelegation {
        calls.append(AuthorizationCall(
            surfaceID: surfaceID,
            delegateIdentity: delegateIdentity,
            replacing: replacing
        ))
        if let replacing, mutateSameGenerationNext {
            mutateSameGenerationNext = false
            return try mutatedSameGeneration(replacing)
        }
        if let replacing, !replaceNext { return replacing }
        if let replacing { revocations.append(replacing) }
        replaceNext = false
        let scopes = nextScopes
        nextScopes = ["text"]
        let sequence = nextDelegationSequence
        nextDelegationSequence = 1
        defer { nextGeneration += 1 }
        let delegation = try JSONDecoder().decode(
            BackendTerminalInputDelegation.self,
            from: JSONSerialization.data(withJSONObject: [
                "surface_uuid": surfaceID.description,
                "delegation_id": UUID().uuidString.lowercased(),
                "delegation_generation": nextGeneration,
                "owner_lease_generation": 41,
                "delegate_client_uuid": delegateIdentity.clientUUID.uuidString.lowercased(),
                "delegate_process_instance_uuid": delegateIdentity.processInstanceUUID
                    .uuidString.lowercased(),
                "expires_at_ms": 90_000 + nextGeneration,
                "scopes": scopes,
                "next_sequence": sequence,
            ])
        )
        issued.append(delegation)
        return delegation
    }

    func revokeTerminalCompatibilityInput(
        surfaceID: SurfaceID,
        delegateIdentity: BackendClientRegistrationIdentity,
        delegation: BackendTerminalInputDelegation
    ) async throws {
        guard delegation.surfaceID == surfaceID,
              delegation.delegateClientUUID == delegateIdentity.clientUUID,
              delegation.delegateProcessInstanceUUID
                == delegateIdentity.processInstanceUUID else {
            throw BackendProtocolError.malformedMessage
        }
        revocations.append(delegation)
    }

    func replaceOnNextAuthorization(nextSequence: UInt64 = 1) {
        replaceNext = true
        nextDelegationSequence = nextSequence
    }

    func mutateSameGenerationOnNextAuthorization() {
        mutateSameGenerationNext = true
    }

    func useScopesOnNextAuthorization(_ scopes: [String]) {
        nextScopes = scopes
    }

    func authorizationCalls() -> [AuthorizationCall] { calls }

    func revokedDelegations() -> [BackendTerminalInputDelegation] { revocations }

    func issuedDelegations() -> [BackendTerminalInputDelegation] { issued }

    private func mutatedSameGeneration(
        _ delegation: BackendTerminalInputDelegation
    ) throws -> BackendTerminalInputDelegation {
        try JSONDecoder().decode(
            BackendTerminalInputDelegation.self,
            from: JSONSerialization.data(withJSONObject: [
                "surface_uuid": delegation.surfaceID.description,
                "delegation_id": delegation.delegationID.uuidString.lowercased(),
                "delegation_generation": delegation.delegationGeneration,
                "owner_lease_generation": delegation.ownerLeaseGeneration,
                "delegate_client_uuid": delegation.delegateClientUUID.uuidString.lowercased(),
                "delegate_process_instance_uuid": delegation.delegateProcessInstanceUUID
                    .uuidString.lowercased(),
                "expires_at_ms": delegation.expiresAtMilliseconds + 1,
                "scopes": delegation.scopes.map(\.rawValue),
                "next_sequence": delegation.nextSequence + 1,
            ])
        )
    }
}
