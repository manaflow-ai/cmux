import CmuxTerminalBackend
import Foundation
import Testing

@Suite("Canonical backend session")
struct BackendCanonicalSessionTests {
    @Test("v9 registers before topology and serializes leased input and geometry")
    func leasedTerminalControl() async throws {
        let transport = ScriptedBackendTransport()
        let authority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: SessionID(rawValue: UUID())
        )
        let identity = fixedRegistrationIdentity()
        let connectionID = try #require(
            UUID(uuidString: "33333333-3333-4333-8333-333333333333")
        )
        let session = BackendCanonicalSession(
            transport: transport,
            expectation: BackendCanonicalSessionExpectation(
                session: "app-session",
                authority: authority,
                processID: 4321
            ),
            registrationIdentity: identity
        )

        let connectTask = Task { try await session.connect() }
        try await completeV9Handshake(
            transport: transport,
            authority: authority,
            session: "app-session",
            processID: 4321,
            identity: identity,
            connectionID: connectionID
        )
        _ = try await connectTask.value
        #expect(try await session.terminalControlProtocol() == .leasedV9)

        let surfaceID = SurfaceID(rawValue: UUID())
        let presentationID = PresentationID(rawValue: UUID())
        let inputLeaseID = UUID()
        let geometryLeaseID = UUID()
        let acquireTask = Task {
            try await session.acquireTerminalControl(
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 7,
                ttlMilliseconds: 5_000
            )
        }
        let acquire = try requestObject(await transport.nextSent())
        #expect(acquire["cmd"] as? String == "acquire-terminal-lease")
        #expect(acquire["kind"] as? String == "input")
        #expect(acquire["surface_uuid"] as? String == surfaceID.description)
        #expect(acquire["presentation_id"] as? String == presentationID.description)
        #expect(try uint64(acquire, "presentation_generation") == 7)
        await transport.enqueue(try response(
            to: acquire,
            data: leaseResponse(
                kind: .input,
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 7,
                leaseID: inputLeaseID,
                leaseGeneration: 3,
                nextSequence: 4,
                migratedFromLegacy: true
            )
        ))
        let geometryAcquire = try requestObject(await transport.nextSent())
        #expect(geometryAcquire["cmd"] as? String == "acquire-terminal-lease")
        #expect(geometryAcquire["kind"] as? String == "geometry")
        await transport.enqueue(try response(
            to: geometryAcquire,
            data: leaseResponse(
                kind: .geometry,
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 7,
                leaseID: geometryLeaseID,
                leaseGeneration: 9,
                nextSequence: 8
            )
        ))
        let lease = try await acquireTask.value
        #expect(lease.connectionID == connectionID)
        #expect(lease.nextInputSequence == 4)
        #expect(lease.nextGeometrySequence == 8)

        let firstRequestID = UUID()
        let firstInputTask = Task {
            try await session.sendTerminalInput(
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 7,
                requestID: firstRequestID,
                input: .text("hello", paste: false)
            )
        }
        let firstInput = try requestObject(await transport.nextSent())
        #expect(firstInput["cmd"] as? String == "terminal-input")
        #expect(try uint64(firstInput, "sequence") == 4)
        let firstPayload = try #require(firstInput["input"] as? [String: Any])
        #expect(firstPayload["type"] as? String == "text")
        #expect(firstPayload["text"] as? String == "hello")
        await transport.enqueue(try response(
            to: firstInput,
            data: inputReceipt(
                requestID: firstRequestID,
                sequence: 4,
                leaseGeneration: 3,
                encodedBytes: 5
            )
        ))
        #expect(try await firstInputTask.value.encodedBytes == 5)

        let secondRequestID = UUID()
        let secondInputTask = Task {
            try await session.sendTerminalInput(
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 7,
                requestID: secondRequestID,
                input: .namedKey("enter")
            )
        }
        let secondInput = try requestObject(await transport.nextSent())
        #expect(try uint64(secondInput, "sequence") == 5)
        await transport.enqueue(try response(
            to: secondInput,
            data: inputReceipt(
                requestID: secondRequestID,
                sequence: 5,
                leaseGeneration: 3,
                encodedBytes: 1
            )
        ))
        #expect(try await secondInputTask.value.encodedBytes == 1)

        let geometryRequestID = UUID()
        let geometryTask = Task {
            try await session.sendTerminalGeometry(
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 7,
                requestID: geometryRequestID,
                columns: 132,
                rows: 43
            )
        }
        let geometry = try requestObject(await transport.nextSent())
        #expect(geometry["cmd"] as? String == "terminal-geometry")
        #expect(try uint64(geometry, "sequence") == 8)
        await transport.enqueue(try response(
            to: geometry,
            data: geometryReceipt(
                requestID: geometryRequestID,
                sequence: 8,
                leaseGeneration: 9,
                columns: 132,
                rows: 43
            )
        ))
        #expect(try await geometryTask.value.columns == 132)

        let staleRequestID = UUID()
        let staleTask = Task {
            try await session.sendTerminalInput(
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 7,
                requestID: staleRequestID,
                input: .namedKey("tab")
            )
        }
        let stale = try requestObject(await transport.nextSent())
        #expect(try uint64(stale, "sequence") == 6)
        await transport.enqueue(try response(
            to: stale,
            data: inputReceipt(
                requestID: staleRequestID,
                sequence: 99,
                leaseGeneration: 3,
                encodedBytes: 1
            )
        ))
        await #expect(throws: BackendProtocolError.malformedMessage) {
            try await staleTask.value
        }

        let releaseTask = Task {
            try await session.releaseTerminalControl(
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 7
            )
        }
        let release = try requestObject(await transport.nextSent())
        #expect(release["cmd"] as? String == "release-terminal-lease")
        #expect(release["kind"] as? String == "input")
        #expect(release["lease_id"] as? String == inputLeaseID.uuidString.lowercased())
        #expect(try uint64(release, "lease_generation") == 3)
        await transport.enqueue(try response(to: release, data: [:]))
        let geometryRelease = try requestObject(await transport.nextSent())
        #expect(geometryRelease["cmd"] as? String == "release-terminal-lease")
        #expect(geometryRelease["kind"] as? String == "geometry")
        #expect(
            geometryRelease["lease_id"] as? String
                == geometryLeaseID.uuidString.lowercased()
        )
        await transport.enqueue(try response(to: geometryRelease, data: [:]))
        try await releaseTask.value
        await session.close()
    }

    @Test("v9 refreshes an expiring lease before ordered input")
    func refreshesTerminalControlLeaseBeforeInput() async throws {
        let transport = ScriptedBackendTransport()
        let authority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: SessionID(rawValue: UUID())
        )
        let identity = fixedRegistrationIdentity()
        let connectionID = UUID()
        let session = BackendCanonicalSession(
            transport: transport,
            expectation: BackendCanonicalSessionExpectation(
                session: "app-session",
                authority: authority,
                processID: 4321
            ),
            registrationIdentity: identity
        )

        let connectTask = Task { try await session.connect() }
        try await completeV9Handshake(
            transport: transport,
            authority: authority,
            session: "app-session",
            processID: 4321,
            identity: identity,
            connectionID: connectionID
        )
        _ = try await connectTask.value

        let surfaceID = SurfaceID(rawValue: UUID())
        let presentationID = PresentationID(rawValue: UUID())
        let inputLeaseID = UUID()
        let geometryLeaseID = UUID()
        let acquireTask = Task {
            try await session.acquireTerminalControl(
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 2,
                ttlMilliseconds: 1
            )
        }
        let acquire = try requestObject(await transport.nextSent())
        await transport.enqueue(try response(
            to: acquire,
            data: leaseResponse(
                kind: .input,
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 2,
                leaseID: inputLeaseID,
                leaseGeneration: 4,
                nextSequence: 7,
                migratedFromLegacy: true
            )
        ))
        let geometryAcquire = try requestObject(await transport.nextSent())
        await transport.enqueue(try response(
            to: geometryAcquire,
            data: leaseResponse(
                kind: .geometry,
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 2,
                leaseID: geometryLeaseID,
                leaseGeneration: 6,
                nextSequence: 11
            )
        ))
        _ = try await acquireTask.value

        let requestID = UUID()
        let inputTask = Task {
            try await session.sendTerminalInput(
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 2,
                requestID: requestID,
                input: .text("x", paste: false)
            )
        }

        let refresh = try requestObject(await transport.nextSent())
        #expect(refresh["cmd"] as? String == "renew-terminal-lease")
        #expect(refresh["kind"] as? String == "input")
        #expect(try uint64(refresh, "ttl_ms") == 1)
        await transport.enqueue(try response(
            to: refresh,
            data: leaseResponse(
                kind: .input,
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 2,
                leaseID: inputLeaseID,
                leaseGeneration: 4,
                nextSequence: 7
            )
        ))

        let input = try requestObject(await transport.nextSent())
        #expect(input["cmd"] as? String == "terminal-input")
        #expect(try uint64(input, "sequence") == 7)
        await transport.enqueue(try response(
            to: input,
            data: inputReceipt(
                requestID: requestID,
                sequence: 7,
                leaseGeneration: 4,
                encodedBytes: 1
            )
        ))
        #expect(try await inputTask.value.encodedBytes == 1)
        await session.close()
    }

    @Test("input and geometry overlap while rollover and drag input remain legal")
    func splitLeaseLanesAndAutomaticInputGroups() async throws {
        let transport = ScriptedBackendTransport()
        let authority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: SessionID(rawValue: UUID())
        )
        let identity = fixedRegistrationIdentity()
        let session = BackendCanonicalSession(
            transport: transport,
            expectation: BackendCanonicalSessionExpectation(
                session: "app-session",
                authority: authority,
                processID: 4321
            ),
            registrationIdentity: identity
        )
        let connectTask = Task { try await session.connect() }
        try await completeV9Handshake(
            transport: transport,
            authority: authority,
            session: "app-session",
            processID: 4321,
            identity: identity,
            connectionID: UUID()
        )
        _ = try await connectTask.value

        let surfaceID = SurfaceID(rawValue: UUID())
        let presentationID = PresentationID(rawValue: UUID())
        let inputLeaseID = UUID()
        let geometryLeaseID = UUID()
        let acquireTask = Task {
            try await session.acquireTerminalControl(
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 2,
                ttlMilliseconds: 5_000
            )
        }
        let inputAcquire = try requestObject(await transport.nextSent())
        await transport.enqueue(try response(
            to: inputAcquire,
            data: leaseResponse(
                kind: .input,
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 2,
                leaseID: inputLeaseID,
                leaseGeneration: 4,
                nextSequence: 1,
                migratedFromLegacy: true
            )
        ))
        let geometryAcquire = try requestObject(await transport.nextSent())
        await transport.enqueue(try response(
            to: geometryAcquire,
            data: leaseResponse(
                kind: .geometry,
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 2,
                leaseID: geometryLeaseID,
                leaseGeneration: 8,
                nextSequence: 1
            )
        ))
        _ = try await acquireTask.value

        let pressRequestID = UUID()
        let geometryRequestID = UUID()
        let pressTask = Task {
            try await session.sendTerminalInput(
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 2,
                requestID: pressRequestID,
                input: .key(BackendTerminalKeyEvent(key: 42, action: .press))
            )
        }
        let geometryTask = Task {
            try await session.sendTerminalGeometry(
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 2,
                requestID: geometryRequestID,
                columns: 100,
                rows: 30
            )
        }

        // Both calls must reach the transport before either response. A single
        // combined lease/serialization lane would deadlock on the second read.
        let first = try requestObject(await transport.nextSent())
        let second = try requestObject(await transport.nextSent())
        let press = try #require(
            [first, second].first { $0["cmd"] as? String == "terminal-input" }
        )
        let geometry = try #require(
            [first, second].first { $0["cmd"] as? String == "terminal-geometry" }
        )
        let groupID = try #require(press["input_group_id"] as? String)
        #expect(try uint64(press, "input_group_index") == 0)
        #expect(press["input_group_end"] as? Bool == true)
        await transport.enqueue(try response(
            to: geometry,
            data: geometryReceipt(
                requestID: geometryRequestID,
                sequence: 1,
                leaseGeneration: 8,
                columns: 100,
                rows: 30
            )
        ))
        await transport.enqueue(try response(
            to: press,
            data: inputReceipt(
                requestID: pressRequestID,
                sequence: 1,
                leaseGeneration: 4,
                encodedBytes: 1
            )
        ))
        _ = try await pressTask.value
        _ = try await geometryTask.value

        let mousePressRequestID = UUID()
        let mousePressTask = Task {
            try await session.sendTerminalInput(
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 2,
                requestID: mousePressRequestID,
                input: .mouse(BackendTerminalCellMouseEvent(
                    action: .press,
                    button: .left,
                    column: 2,
                    row: 3,
                    anyButtonPressed: true
                ))
            )
        }
        let mousePress = try requestObject(await transport.nextSent())
        let mouseGroupID = try #require(mousePress["input_group_id"] as? String)
        #expect(mouseGroupID != groupID)
        #expect(mousePress["input_group_end"] as? Bool == true)
        await transport.enqueue(try response(
            to: mousePress,
            data: inputReceipt(
                requestID: mousePressRequestID,
                sequence: 2,
                leaseGeneration: 4,
                encodedBytes: 6
            )
        ))
        _ = try await mousePressTask.value

        // A second key-down during key rollover and an active mouse drag must
        // not inherit either earlier physical event's atomic group.
        let rolloverRequestID = UUID()
        let rolloverTask = Task {
            try await session.sendTerminalInput(
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 2,
                requestID: rolloverRequestID,
                input: .key(BackendTerminalKeyEvent(key: 43, action: .press))
            )
        }
        let rollover = try requestObject(await transport.nextSent())
        let rolloverGroupID = try #require(rollover["input_group_id"] as? String)
        #expect(rolloverGroupID != groupID)
        #expect(rolloverGroupID != mouseGroupID)
        #expect(rollover["input_group_end"] as? Bool == true)
        await transport.enqueue(try response(
            to: rollover,
            data: inputReceipt(
                requestID: rolloverRequestID,
                sequence: 3,
                leaseGeneration: 4,
                encodedBytes: 1
            )
        ))
        _ = try await rolloverTask.value

        let mouseReleaseRequestID = UUID()
        let mouseReleaseTask = Task {
            try await session.sendTerminalInput(
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 2,
                requestID: mouseReleaseRequestID,
                input: .mouse(BackendTerminalCellMouseEvent(
                    action: .release,
                    button: .left,
                    column: 2,
                    row: 3
                ))
            )
        }
        let mouseRelease = try requestObject(await transport.nextSent())
        #expect(mouseRelease["input_group_id"] as? String != mouseGroupID)
        #expect(mouseRelease["input_group_end"] as? Bool == true)
        await transport.enqueue(try response(
            to: mouseRelease,
            data: inputReceipt(
                requestID: mouseReleaseRequestID,
                sequence: 4,
                leaseGeneration: 4,
                encodedBytes: 6
            )
        ))
        _ = try await mouseReleaseTask.value

        let releaseRequestID = UUID()
        let releaseTask = Task {
            try await session.sendTerminalInput(
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 2,
                requestID: releaseRequestID,
                input: .key(BackendTerminalKeyEvent(key: 42, action: .release))
            )
        }
        let release = try requestObject(await transport.nextSent())
        #expect(release["input_group_id"] as? String != groupID)
        #expect(try uint64(release, "input_group_index") == 0)
        #expect(release["input_group_end"] as? Bool == true)
        await transport.enqueue(try response(
            to: release,
            data: inputReceipt(
                requestID: releaseRequestID,
                sequence: 5,
                leaseGeneration: 4,
                encodedBytes: 0
            )
        ))
        _ = try await releaseTask.value
        await session.close()
    }

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
            ),
            registrationIdentity: testRegistrationIdentity()
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
        let initial = try #require(try await connectTask.value)
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

    @Test("missing batch capability falls back to ordered singular terminal ensures")
    func ensureTerminalsFallsBackWithoutBatchCapability() async throws {
        let transport = ScriptedBackendTransport()
        let authority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: SessionID(rawValue: UUID())
        )
        let identity = testRegistrationIdentity()
        let session = BackendCanonicalSession(
            transport: transport,
            expectation: BackendCanonicalSessionExpectation(
                session: "app-session",
                authority: authority,
                processID: 4321
            ),
            registrationIdentity: identity
        )

        let connectTask = Task { try await session.connect() }
        try await completeV9Handshake(
            transport: transport,
            authority: authority,
            session: "app-session",
            processID: 4321,
            identity: identity,
            connectionID: UUID()
        )
        _ = try await connectTask.value

        let requests = (0 ..< 2).map { _ in
            BackendEnsureTerminalRequest(
                workspaceID: WorkspaceID(rawValue: UUID()),
                surfaceID: SurfaceID(rawValue: UUID()),
                arguments: ["/bin/sh"],
                columns: 90,
                rows: 30
            )
        }
        let ensureTask = Task { try await session.ensureTerminals(requests) }
        for (index, expected) in requests.enumerated() {
            let request = try requestObject(await transport.nextSent())
            #expect(request["cmd"] as? String == "ensure-terminal")
            #expect(request["workspace_uuid"] as? String == expected.workspaceID.description)
            #expect(request["surface_uuid"] as? String == expected.surfaceID.description)
            await transport.enqueue(try response(
                to: request,
                data: [
                    "created": true,
                    "workspace": 10 + index,
                    "workspace_uuid": expected.workspaceID.description,
                    "screen": 20 + index,
                    "screen_uuid": UUID().uuidString,
                    "pane": 30 + index,
                    "pane_uuid": UUID().uuidString,
                    "surface": 40 + index,
                    "surface_uuid": expected.surfaceID.description,
                ]
            ))
        }

        let placements = try await ensureTask.value
        #expect(placements.map(\.workspaceID) == requests.map(\.workspaceID))
        #expect(placements.map(\.surfaceID) == requests.map(\.surfaceID))
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
            expectation: BackendCanonicalSessionExpectation(session: "expected"),
            registrationIdentity: testRegistrationIdentity()
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

    @Test("terminal activity restores per-reader receipts and applies ordered events")
    func terminalActivityRestoresReceiptsAndEvents() async throws {
        let authority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: SessionID(rawValue: UUID())
        )
        let identity = fixedRegistrationIdentity()
        let surfaceID = SurfaceID(rawValue: UUID())
        let topology = try topologyDelta(authority: authority, surfaceID: surfaceID).replacement
        let topologyObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(topology)) as? [String: Any]
        )
        let firstTransport = ScriptedBackendTransport()
        let firstSession = BackendCanonicalSession(
            transport: firstTransport,
            expectation: BackendCanonicalSessionExpectation(
                session: "activity-session",
                authority: authority,
                processID: 4321
            ),
            registrationIdentity: identity
        )
        var firstEvents = await firstSession.events().makeAsyncIterator()
        let firstConnect = Task { try await firstSession.connect() }
        try await completeV9Handshake(
            transport: firstTransport,
            authority: authority,
            session: "activity-session",
            processID: 4321,
            identity: identity,
            connectionID: UUID(),
            topology: topologyObject,
            activity: activitySnapshot(
                readerUUID: identity.clientUUID,
                surfaceID: surfaceID,
                latestSequence: 4,
                seenSequence: nil
            )
        )
        _ = try await firstConnect.value

        guard case .snapshot? = await firstEvents.next() else {
            Issue.record("missing topology snapshot event")
            return
        }
        guard case .terminalActivitySnapshot(let installed)? = await firstEvents.next() else {
            Issue.record("missing terminal activity snapshot event")
            return
        }
        #expect(installed.isUnread(surfaceID: surfaceID))
        #expect(await firstSession.currentTerminalActivitySnapshot()?.latestSequence == 4)

        await firstTransport.enqueue(try encodedJSON([
            "event": "terminal-activity",
            "surface_uuid": surfaceID.description,
            "sequence": 5,
            "kind": "notification",
            "notification": 12,
            "level": "warning",
        ]))
        guard case .terminalActivity(let fact)? = await firstEvents.next() else {
            Issue.record("missing terminal activity fact event")
            return
        }
        #expect(fact.sequence == 5)
        #expect(
            await firstSession.currentTerminalActivitySnapshot()?.isUnread(surfaceID: surfaceID)
                == true
        )

        let mark = Task {
            try await firstSession.markTerminalSeen(
                surfaceID: surfaceID,
                activitySequence: 5
            )
        }
        let markRequest = try requestObject(await firstTransport.nextSent())
        #expect(markRequest["cmd"] as? String == "mark-terminal-seen")
        #expect(markRequest["surface_uuid"] as? String == surfaceID.description)
        #expect(try uint64(markRequest, "activity_sequence") == 5)
        let receipt = [
            "reader_uuid": identity.clientUUID.uuidString,
            "surface_uuid": surfaceID.description,
            "seen_sequence": 5,
        ] as [String: Any]
        await firstTransport.enqueue(try encodedJSON(
            receipt.merging(["event": "terminal-activity-receipt"]) { _, event in event }
        ))
        await firstTransport.enqueue(try response(to: markRequest, data: receipt))
        #expect(try await mark.value.seenSequence == 5)
        guard case .terminalActivityReceipt(let appliedReceipt)? = await firstEvents.next() else {
            Issue.record("missing terminal activity receipt event")
            return
        }
        #expect(appliedReceipt.readerUUID == identity.clientUUID)
        #expect(
            await firstSession.currentTerminalActivitySnapshot()?.isUnread(surfaceID: surfaceID)
                == false
        )
        await firstSession.close()

        // A new process connection uses the same stable descriptor UUID. The
        // daemon-restored receipt therefore remains read after reconnect.
        let secondTransport = ScriptedBackendTransport()
        let secondSession = BackendCanonicalSession(
            transport: secondTransport,
            expectation: BackendCanonicalSessionExpectation(
                session: "activity-session",
                authority: authority,
                processID: 4321
            ),
            registrationIdentity: identity
        )
        let secondConnect = Task { try await secondSession.connect() }
        try await completeV9Handshake(
            transport: secondTransport,
            authority: authority,
            session: "activity-session",
            processID: 4321,
            identity: identity,
            connectionID: UUID(),
            topology: topologyObject,
            activity: activitySnapshot(
                readerUUID: identity.clientUUID,
                surfaceID: surfaceID,
                latestSequence: 5,
                seenSequence: 5
            )
        )
        _ = try await secondConnect.value
        #expect(
            await secondSession.currentTerminalActivitySnapshot()?.isUnread(surfaceID: surfaceID)
                == false
        )
        await secondSession.close()
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
            ),
            registrationIdentity: testRegistrationIdentity()
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

    private func completeV9Handshake(
        transport: ScriptedBackendTransport,
        authority: BackendAuthority,
        session: String,
        processID: UInt32,
        identity: BackendClientRegistrationIdentity,
        connectionID: UUID,
        topology: [String: Any] = ["workspaces": []],
        activity: [String: Any]? = nil
    ) async throws {
        let identify = try requestObject(await transport.nextSent())
        #expect(identify["cmd"] as? String == "identify")
        await transport.enqueue(try response(
            to: identify,
            data: [
                "app": "cmux-tui",
                "version": "0.1.0",
                "protocol": 8,
                "protocol_min": 8,
                "protocol_max": 9,
                "capabilities": [
                    "canonical-topology-snapshot-v1",
                    "durable-session-identity-v1",
                    "ensure-terminal-v1",
                    "presentation-registry-v1",
                    "projection-state-reconnect-v1",
                    "renderer-semantic-scene-v1",
                    "renderer-worker-supervision-v1",
                    "reparent-terminal-v1",
                    "stable-entity-uuid-v1",
                    "terminal-accessibility-v1",
                    "terminal-control-lease-v1",
                    "terminal-split-leases-v1",
                    "terminal-lease-transfer-v1",
                    "terminal-input-delegation-v1",
                    "terminal-input-groups-v1",
                    "terminal-global-input-order-v1",
                    "terminal-input-idempotency-v1",
                    "terminal-input-receipt-ack-v1",
                    "terminal-interaction-v1",
                    "terminal-link-hit-v1",
                    "terminal-ordered-input-v1",
                    "terminal-activity-v1",
                    "topology-resume-v1",
                ],
                "session": session,
                "session_id": authority.sessionID.description,
                "daemon_instance_id": authority.daemonInstanceID.description,
                "topology_revision": 0,
                "canonical_topology_revision": 0,
                "pid": processID,
            ]
        ))

        let register = try requestObject(await transport.nextSent())
        #expect(register["cmd"] as? String == "register-client")
        #expect(try uint64(register, "protocol_min") == 9)
        #expect(try uint64(register, "protocol_max") == 9)
        #expect(
            register["client_uuid"] as? String
                == identity.clientUUID.uuidString.lowercased()
        )
        await transport.enqueue(try response(
            to: register,
            data: [
                "protocol": 9,
                "connection_id": connectionID.uuidString,
                "client_uuid": identity.clientUUID.uuidString,
                "process_instance_uuid": identity.processInstanceUUID.uuidString,
            ]
        ))

        let snapshot = try requestObject(await transport.nextSent())
        #expect(snapshot["cmd"] as? String == "topology-snapshot")
        await transport.enqueue(try response(
            to: snapshot,
            data: [
                "daemon_instance_id": authority.daemonInstanceID.description,
                "session_id": authority.sessionID.description,
                "revision": 0,
                "topology": topology,
            ]
        ))

        let subscribe = try requestObject(await transport.nextSent())
        #expect(subscribe["cmd"] as? String == "subscribe-topology")
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

        let activityRequest = try requestObject(await transport.nextSent())
        #expect(activityRequest["cmd"] as? String == "terminal-activity-snapshot")
        await transport.enqueue(try response(
            to: activityRequest,
            data: activity ?? [
                "reader_uuid": identity.clientUUID.uuidString,
                "latest_sequence": 0,
                "facts": [],
                "receipts": [],
            ]
        ))
    }

    private func activitySnapshot(
        readerUUID: UUID,
        surfaceID: SurfaceID,
        latestSequence: UInt64,
        seenSequence: UInt64?
    ) -> [String: Any] {
        var receipts: [[String: Any]] = []
        if let seenSequence {
            receipts.append([
                "reader_uuid": readerUUID.uuidString,
                "surface_uuid": surfaceID.description,
                "seen_sequence": seenSequence,
            ])
        }
        return [
            "reader_uuid": readerUUID.uuidString,
            "latest_sequence": latestSequence,
            "facts": [[
                "surface_uuid": surfaceID.description,
                "sequence": latestSequence,
                "kind": "notification",
                "notification": 11,
                "level": "info",
            ]],
            "receipts": receipts,
        ]
    }

    private func leaseResponse(
        kind: BackendTerminalLeaseKind,
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        leaseID: UUID,
        leaseGeneration: UInt64,
        nextSequence: UInt64,
        migratedFromLegacy: Bool = false
    ) -> [String: Any] {
        var response: [String: Any] = [
            "kind": kind.rawValue,
            "surface_uuid": surfaceID.description,
            "presentation_id": presentationID.description,
            "presentation_generation": presentationGeneration,
            "lease_id": leaseID.uuidString,
            "lease_generation": leaseGeneration,
            "revocation_sequence": 0,
            "expires_at_ms": 90_000,
            "next_sequence": nextSequence,
            "migrated_from_legacy": migratedFromLegacy,
        ]
        if kind == .input {
            response["next_global_input_sequence"] = 1
        }
        return response
    }

    private func inputReceipt(
        requestID: UUID,
        sequence: UInt64,
        leaseGeneration: UInt64,
        encodedBytes: UInt64
    ) -> [String: Any] {
        [
            "request_id": requestID.uuidString,
            "status": "applied",
            "kind": "input",
            "sequence": sequence,
            "ordered_input_sequence": sequence,
            "lease_generation": leaseGeneration,
            "replayed": false,
            "encoded_bytes": encodedBytes,
            "lease_revoked": false,
        ]
    }

    private func geometryReceipt(
        requestID: UUID,
        sequence: UInt64,
        leaseGeneration: UInt64,
        columns: UInt16,
        rows: UInt16
    ) -> [String: Any] {
        [
            "request_id": requestID.uuidString,
            "status": "applied",
            "kind": "geometry",
            "sequence": sequence,
            "lease_generation": leaseGeneration,
            "replayed": false,
            "cols": columns,
            "rows": rows,
            "changed": true,
            "lease_revoked": false,
        ]
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
                    "ensure-terminal-v1",
                    "presentation-registry-v1",
                    "projection-state-reconnect-v1",
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

private func testRegistrationIdentity() -> BackendClientRegistrationIdentity {
    BackendClientRegistrationIdentity(
        clientUUID: UUID(),
        processInstanceUUID: UUID()
    )!
}

private func fixedRegistrationIdentity() -> BackendClientRegistrationIdentity {
    BackendClientRegistrationIdentity(
        clientUUID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        processInstanceUUID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    )!
}
