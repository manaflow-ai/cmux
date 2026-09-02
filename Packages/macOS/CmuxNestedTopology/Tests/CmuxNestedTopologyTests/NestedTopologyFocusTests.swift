import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct NestedTopologyFocusTests {
    @Test func allowedFocusForwardsTypedTargetWithoutOptimisticFocus() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }

        let attachmentIDBox = MutexBox<UUID?>(nil)
        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake(instance: "focus-live") },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: attachmentIDBox.get() ?? UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    instance: "focus-live"
                )
            },
            events: {
                AsyncThrowingStream { continuation in
                    continuation.onTermination = { _ in }
                }
            }
        )
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )

        let record = try await coordinator.attach(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            providerKind: .herdr,
            socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
            authorization: .userConfirmed
        )
        attachmentIDBox.set(record.attachmentID)
        let paneID = try #require(record.latestSnapshot?.panes.first?.id)
        let focusBefore = try #require(record.latestSnapshot?.focus)

        let result = try await coordinator.focusNode(
            NestedNodeFocusRequest(
                hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                nodeID: paneID,
                expectedAttachmentID: record.attachmentID,
                expectedProviderInstanceID: record.providerInstanceID,
                authorization: .userConfirmed
            )
        )
        #expect(result.accepted)
        #expect(result.nodeID == paneID)
        #expect(await client.focusCount == 1)
        #expect(await client.lastFocusedNodeID == paneID)

        // No optimistic focus invention — snapshot focus unchanged until events.
        let after = try #require(await coordinator.attachment(for: AttachmentTestFixtures.surfaceA))
        #expect(after.latestSnapshot?.focus == focusBefore)
    }

    @Test func capabilityAbsentRejectsFocusWithoutCallingProvider() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }

        let readOnly = NestedCapabilitySet(capabilities: [.topologySnapshotV1, .topologyEventsV1])
        let client = StubNestedTopologyProviderClient(
            handshake: {
                AttachmentTestFixtures.handshake(instance: "no-focus", capabilities: readOnly)
            },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    instance: "no-focus"
                )
            },
            events: {
                AsyncThrowingStream { continuation in
                    continuation.onTermination = { _ in }
                }
            }
        )
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )
        let record = try await coordinator.attach(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            providerKind: .herdr,
            socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
            authorization: .userConfirmed
        )
        let paneID = try #require(record.latestSnapshot?.panes.first?.id)

        do {
            _ = try await coordinator.focusNode(
                NestedNodeFocusRequest(
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    nodeID: paneID,
                    authorization: .userConfirmed
                )
            )
            Issue.record("expected capability absent")
        } catch let error as NestedAttachmentError {
            #expect(error == .capabilityAbsent(.topologyFocusV1))
            #expect(error.socketErrorCode == "capability_absent")
        }
        #expect(await client.focusCount == 0)
    }

    @Test func staleProviderInstanceRejected() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }

        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake(instance: "gen-1") },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    instance: "gen-1"
                )
            },
            events: {
                AsyncThrowingStream { continuation in
                    continuation.onTermination = { _ in }
                }
            }
        )
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )
        let record = try await coordinator.attach(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            providerKind: .herdr,
            socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
            authorization: .userConfirmed
        )
        let paneID = try #require(record.latestSnapshot?.panes.first?.id)
        let staleNode = NestedNodeID(
            providerKind: .herdr,
            providerInstanceID: NestedProviderInstanceID(rawValue: "gen-stale"),
            kind: .pane,
            rawID: paneID.rawID
        )

        do {
            _ = try await coordinator.focusNode(
                NestedNodeFocusRequest(
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    nodeID: staleNode,
                    expectedProviderInstanceID: NestedProviderInstanceID(rawValue: "gen-stale"),
                    authorization: .authenticatedControlSocket(requestID: "req-stale")
                )
            )
            Issue.record("expected stale instance rejection")
        } catch let error as NestedAttachmentError {
            #expect(error == .providerInstanceMismatch || error.socketErrorCode == "stale_instance")
        }
        #expect(await client.focusCount == 0)
    }

    @Test func nodeClosedDuringActionRejectedAfterProviderReturns() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }

        let eventContinuation = MutexBox<AsyncThrowingStream<NestedTopologyEvent, any Error>.Continuation?>(nil)
        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake(instance: "close-race") },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    instance: "close-race"
                )
            },
            events: {
                AsyncThrowingStream { continuation in
                    eventContinuation.set(continuation)
                    continuation.onTermination = { _ in }
                }
            },
            focus: { nodeID in
                // While focus RPC is in flight, close the pane via event stream.
                // Poll until the subscriber is ready, then give the coordinator
                // actor time to apply the close before this RPC returns.
                for _ in 0..<50 {
                    if let continuation = eventContinuation.get() {
                        continuation.yield(.paneClosed(nodeID))
                        try await Task.sleep(for: .milliseconds(50))
                        return
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
                Issue.record("event subscriber never became ready during focus")
            }
        )
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )
        let record = try await coordinator.attach(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            providerKind: .herdr,
            socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
            authorization: .userConfirmed
        )
        let paneID = try #require(record.latestSnapshot?.panes.first?.id)

        // Wait for event observation to start.
        for _ in 0..<50 {
            if eventContinuation.get() != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        do {
            _ = try await coordinator.focusNode(
                NestedNodeFocusRequest(
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    nodeID: paneID,
                    authorization: .userConfirmed
                )
            )
            Issue.record("expected node-not-found after close during action")
        } catch let error as NestedAttachmentError {
            guard case .nodeNotFound = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(error.socketErrorCode == "not_found")
        }
    }

    @Test func focusChangedEventReconcilesWithoutOptimisticRPCMutation() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }

        let eventContinuation = MutexBox<AsyncThrowingStream<NestedTopologyEvent, any Error>.Continuation?>(nil)
        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake(instance: "event-race") },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    instance: "event-race"
                )
            },
            events: {
                AsyncThrowingStream { continuation in
                    eventContinuation.set(continuation)
                    continuation.onTermination = { _ in }
                }
            }
        )
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )
        let record = try await coordinator.attach(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            providerKind: .herdr,
            socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
            authorization: .userConfirmed
        )
        let workspaceID = try #require(record.latestSnapshot?.workspaces.first?.id)
        try await Task.sleep(for: .milliseconds(30))

        let eventFocus = NestedFocus(workspaceID: workspaceID)
        eventContinuation.get()?.yield(.focusChanged(eventFocus))
        try await Task.sleep(for: .milliseconds(40))

        let updated = try #require(await coordinator.attachment(for: AttachmentTestFixtures.surfaceA))
        #expect(updated.latestSnapshot?.focus == eventFocus)
        #expect(await client.focusCount == 0)
    }

    @Test func duplicateRawIDsAcrossAttachmentsFocusIndependently() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }

        let clientA = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake(instance: "dup-a") },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    instance: "dup-a",
                    paneRawID: "w1:p1"
                )
            },
            events: {
                AsyncThrowingStream { continuation in
                    continuation.onTermination = { _ in }
                }
            }
        )
        let clientB = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake(instance: "dup-b") },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceB,
                    instance: "dup-b",
                    paneRawID: "w1:p1"
                )
            },
            events: {
                AsyncThrowingStream { continuation in
                    continuation.onTermination = { _ in }
                }
            }
        )

        let queue = MutexBox([clientA, clientB])
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: SequencingClientFactory { _ in
                queue.mutate { clients in
                    precondition(!clients.isEmpty, "no stub clients remaining")
                    return clients.removeFirst()
                }
            },
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )

        let a = try await coordinator.attach(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            providerKind: .herdr,
            socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
            authorization: .userConfirmed
        )
        let b = try await coordinator.attach(
            hostWorkspaceID: AttachmentTestFixtures.workspaceB,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceB,
            providerKind: .herdr,
            socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
            authorization: .authenticatedControlSocket(requestID: "focus-b")
        )
        let paneA = try #require(a.latestSnapshot?.panes.first?.id)
        let paneB = try #require(b.latestSnapshot?.panes.first?.id)
        #expect(paneA.rawID == paneB.rawID)
        #expect(paneA != paneB)

        _ = try await coordinator.focusNode(
            NestedNodeFocusRequest(
                hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                nodeID: paneA,
                authorization: .userConfirmed
            )
        )
        _ = try await coordinator.focusNode(
            NestedNodeFocusRequest(
                hostStableSurfaceID: AttachmentTestFixtures.surfaceB,
                nodeID: paneB,
                authorization: .authenticatedControlSocket(requestID: "focus-b-2")
            )
        )

        #expect(await clientA.focusCount == 1)
        #expect(await clientA.lastFocusedNodeID == paneA)
        #expect(await clientB.focusCount == 1)
        #expect(await clientB.lastFocusedNodeID == paneB)

        // Cross-host with the other attachment's compound ID must fail.
        do {
            _ = try await coordinator.focusNode(
                NestedNodeFocusRequest(
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    nodeID: paneB,
                    authorization: .userConfirmed
                )
            )
            Issue.record("expected wrong-instance rejection")
        } catch let error as NestedAttachmentError {
            #expect(error == .providerInstanceMismatch)
        }
    }

    @Test func controlSocketAuthorizationRequiredForFocus() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }

        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake(instance: "auth") },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    instance: "auth"
                )
            },
            events: {
                AsyncThrowingStream { continuation in
                    continuation.onTermination = { _ in }
                }
            }
        )
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )
        let record = try await coordinator.attach(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            providerKind: .herdr,
            socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
            authorization: .userConfirmed
        )
        let paneID = try #require(record.latestSnapshot?.panes.first?.id)

        do {
            _ = try await coordinator.focusNode(
                NestedNodeFocusRequest(
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    nodeID: paneID,
                    authorization: nil
                )
            )
            Issue.record("expected unauthorized")
        } catch let error as NestedAttachmentError {
            #expect(error == .optInRequired)
            #expect(error.socketErrorCode == "unauthorized")
        }

        let accepted = try await coordinator.focusNode(
            NestedNodeFocusRequest(
                hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                nodeID: paneID,
                authorization: .authenticatedControlSocket(requestID: "socket-1")
            )
        )
        #expect(accepted.accepted)
        #expect(await client.focusCount == 1)
    }

    @Test func herdrClientFocusMapsKindsToTypedMethods() async throws {
        let seen = MutexBox<[(String, [String: Any])]>([])
        let server = try FakeHerdrUnixSocketServer { line, id, method in
            if let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let params = object["params"] as? [String: Any]
            {
                seen.mutate { $0.append((method, params)) }
            }
            switch method {
            case "ping":
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.pongJSON(id: id, instanceID: "herdr-focus"))]
            case "workspace.focus", "tab.focus", "pane.focus", "agent.focus":
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.focusOKJSON(id: id, type: "ok"))]
            default:
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.errorJSON(id: id))]
            }
        }
        defer { server.shutdown() }

        let client = HerdrNestedTopologyClient(
            configuration: HerdrNestedTopologyClientConfiguration(
                socketPath: server.path,
                attachmentID: HerdrFakeFixtures.attachmentID,
                hostStableSurfaceID: HerdrFakeFixtures.hostSurfaceID
            )
        )
        let handshake = try await client.handshake()
        #expect(handshake.capabilities.contains(.topologyFocusV1))

        let instance = handshake.providerInstanceID
        try await client.focus(
            nodeID: NestedNodeID(
                providerKind: .herdr,
                providerInstanceID: instance,
                kind: .workspace,
                rawID: "w1"
            )
        )
        try await client.focus(
            nodeID: NestedNodeID(
                providerKind: .herdr,
                providerInstanceID: instance,
                kind: .tab,
                rawID: "w1:t1"
            )
        )
        try await client.focus(
            nodeID: NestedNodeID(
                providerKind: .herdr,
                providerInstanceID: instance,
                kind: .pane,
                rawID: "w1:p1"
            )
        )
        try await client.focus(
            nodeID: NestedNodeID(
                providerKind: .herdr,
                providerInstanceID: instance,
                kind: .agent,
                rawID: "w1:p1"
            )
        )

        let calls = seen.get().filter { $0.0.hasSuffix(".focus") }
        #expect(calls.count == 4)
        #expect(calls[0].0 == "workspace.focus")
        #expect(calls[0].1["workspace_id"] as? String == "w1")
        #expect(calls[1].0 == "tab.focus")
        #expect(calls[1].1["tab_id"] as? String == "w1:t1")
        #expect(calls[2].0 == "pane.focus")
        #expect(calls[2].1["pane_id"] as? String == "w1:p1")
        #expect(calls[3].0 == "agent.focus")
        #expect(calls[3].1["target"] as? String == "w1:p1")
    }

    @Test func publicCapabilityAdvertisesFocusV1() {
        #expect(NestedTopologyPublicCapability.focusV1.rawValue == "nested_topology.focus.v1")
        #expect(
            NestedTopologyPublicCapability.allCases.map(\.rawValue).sorted()
                == [
                    "nested_topology.focus.v1",
                    "nested_topology.read.v1",
                    "nested_topology.window_mirror.v1",
                ]
        )
    }
}
