import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct NestedTopologyRestoreTests {
    @Test func oldSessionPanelSnapshotJSONWithoutIntentStillDecodesDescriptorDefaults() throws {
        // Simulates an older persisted intent object that only had provider_kind.
        let json = """
        {"provider_kind":"herdr"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NestedAttachmentIntentDescriptor.self, from: json)
        #expect(decoded.providerKind == .herdr)
        #expect(decoded.reattachPolicy == .requireConfirmation)
        #expect(decoded.endpointLocator == nil)
        #expect(decoded.lastVerifiedProviderInstanceID == nil)
        #expect(decoded.providerInstanceIdentityProofAvailable == false)
        #expect(decoded.schemaVersion == NestedAttachmentIntentDescriptor.currentSchemaVersion)
    }

    @Test func intentRoundTripDoesNotPersistSecretsOrTopologyPayload() throws {
        let intent = NestedAttachmentIntentDescriptor(
            providerKind: .herdr,
            reattachPolicy: .autoIfProviderInstanceMatches,
            endpointLocator: NestedAttachmentEndpointLocator(
                socketPath: AttachmentTestFixtures.endpoint.canonicalPath
            ),
            lastVerifiedProviderInstanceID: NestedProviderInstanceID(rawValue: "durable-1"),
            providerInstanceIdentityProofAvailable: true,
            lastVerifiedFileIdentity: AttachmentTestFixtures.endpoint.fileIdentity
        )
        let data = try JSONEncoder().encode(intent)
        let decoded = try JSONDecoder().decode(NestedAttachmentIntentDescriptor.self, from: data)
        #expect(decoded == intent)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keys = NestedAttachmentIntentDescriptor.collectJSONKeys(object)
        for forbidden in NestedAttachmentIntentDescriptor.forbiddenPersistenceKeys {
            #expect(keys.contains(forbidden) == false)
        }
        #expect(object["endpoint_locator"] != nil)
        #expect(object["last_verified_provider_instance_id"] as? String == "durable-1")
        // Association / nested topology payload keys must never be written.
        #expect(object["latest_snapshot"] == nil)
        #expect(object["associations"] == nil)
    }

    @Test func makeIntentFromLiveRecordOmitsSnapshotAndChoosesPolicyFromProof() throws {
        var live = NestedAttachmentRecord(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            providerKind: .herdr,
            endpoint: AttachmentTestFixtures.endpoint,
            providerInstanceID: NestedProviderInstanceID(rawValue: "durable-1"),
            providerInstanceIdentityProofAvailable: true,
            state: .live,
            latestSnapshot: AttachmentTestFixtures.snapshot(
                attachmentID: UUID(),
                hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                instance: "durable-1"
            )
        )
        let withProof = try #require(NestedAttachmentIntentDescriptor.make(from: live))
        #expect(withProof.reattachPolicy == .autoIfProviderInstanceMatches)
        #expect(withProof.allowsUnattendedAutoReattach)

        live.providerInstanceIdentityProofAvailable = false
        let withoutProof = try #require(NestedAttachmentIntentDescriptor.make(from: live))
        #expect(withoutProof.reattachPolicy == .requireConfirmation)
        #expect(withoutProof.allowsUnattendedAutoReattach == false)
    }

    @Test func restoreWithoutIdentityProofLeavesDisconnectedPendingConfirmation() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }
        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake(instance: "should-not-run") },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA
                )
            }
        )
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )

        let intent = NestedAttachmentIntentDescriptor(
            providerKind: .herdr,
            reattachPolicy: .autoIfProviderInstanceMatches,
            endpointLocator: NestedAttachmentEndpointLocator(
                socketPath: AttachmentTestFixtures.endpoint.canonicalPath
            ),
            lastVerifiedProviderInstanceID: NestedProviderInstanceID(rawValue: "old"),
            providerInstanceIdentityProofAvailable: false,
            lastVerifiedFileIdentity: AttachmentTestFixtures.endpoint.fileIdentity
        )
        let record = await coordinator.restoreFromIntent(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            intent: intent
        )
        #expect(record.state == .disconnected)
        #expect(record.pendingRestoreIntent != nil)
        #expect(record.latestSnapshot == nil)
        #expect(await client.handshakeCount == 0)
        #expect(
            NestedPluginWriterHandoff(directoryURL: handoffDir)
                .isHeld(hostStableSurfaceID: AttachmentTestFixtures.surfaceA) == false
        )
    }

    @Test func restoreMissingProviderLeavesDisconnected() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }
        let client = StubNestedTopologyProviderClient(
            handshake: { throw NestedTopologyProviderError.transport("missing") },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA
                )
            }
        )
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(
                preConnectResult: .failure(.missing)
            ),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )

        let intent = NestedAttachmentIntentDescriptor(
            providerKind: .herdr,
            reattachPolicy: .autoIfProviderInstanceMatches,
            endpointLocator: NestedAttachmentEndpointLocator(socketPath: "/tmp/missing.sock"),
            lastVerifiedProviderInstanceID: NestedProviderInstanceID(rawValue: "durable-1"),
            providerInstanceIdentityProofAvailable: true,
            lastVerifiedFileIdentity: NestedUnixSocketFileIdentity(deviceID: 1, inode: 2)
        )
        let record = await coordinator.restoreFromIntent(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            intent: intent
        )
        #expect(record.state == .rejected || record.state == .disconnected)
        #expect(record.pendingRestoreIntent != nil)
        #expect(record.latestSnapshot == nil)
        #expect(await client.handshakeCount == 0)
    }

    @Test func restoreChangedSocketIdentityRequiresConfirmation() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }
        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake(instance: "durable-1") },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    instance: "durable-1"
                )
            }
        )
        let swappedEndpoint = NestedAttachmentEndpoint(
            canonicalPath: AttachmentTestFixtures.endpoint.canonicalPath,
            fileIdentity: NestedUnixSocketFileIdentity(deviceID: 99, inode: 100),
            ownerUID: AttachmentTestFixtures.endpoint.ownerUID,
            permissionBits: AttachmentTestFixtures.endpoint.permissionBits
        )
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(swappedEndpoint)),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )

        let intent = NestedAttachmentIntentDescriptor(
            providerKind: .herdr,
            reattachPolicy: .autoIfProviderInstanceMatches,
            endpointLocator: NestedAttachmentEndpointLocator(
                socketPath: AttachmentTestFixtures.endpoint.canonicalPath
            ),
            lastVerifiedProviderInstanceID: NestedProviderInstanceID(rawValue: "durable-1"),
            providerInstanceIdentityProofAvailable: true,
            lastVerifiedFileIdentity: AttachmentTestFixtures.endpoint.fileIdentity
        )
        let record = await coordinator.restoreFromIntent(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            intent: intent
        )
        #expect(record.state == .disconnected)
        #expect(record.lastErrorClass == NestedAttachmentError.restoreSocketIdentityChanged.telemetryErrorClass)
        #expect(record.pendingRestoreIntent != nil)
        #expect(await client.handshakeCount == 0)
    }

    @Test func restoreChangedProviderInstanceRequiresConfirmation() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }
        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake(instance: "new-instance") },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    instance: "new-instance"
                )
            }
        )
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )

        let intent = NestedAttachmentIntentDescriptor(
            providerKind: .herdr,
            reattachPolicy: .autoIfProviderInstanceMatches,
            endpointLocator: NestedAttachmentEndpointLocator(
                socketPath: AttachmentTestFixtures.endpoint.canonicalPath
            ),
            lastVerifiedProviderInstanceID: NestedProviderInstanceID(rawValue: "old-instance"),
            providerInstanceIdentityProofAvailable: true,
            lastVerifiedFileIdentity: AttachmentTestFixtures.endpoint.fileIdentity
        )
        let record = await coordinator.restoreFromIntent(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            intent: intent
        )
        #expect(record.state == .disconnected)
        #expect(record.latestSnapshot == nil)
        #expect(record.pendingRestoreIntent != nil)
        #expect(await client.handshakeCount == 1)
        #expect(await client.snapshotCount == 0)
        #expect(
            NestedPluginWriterHandoff(directoryURL: handoffDir)
                .isHeld(hostStableSurfaceID: AttachmentTestFixtures.surfaceA) == false
        )
    }

    @Test func restoreSuccessfulFreshSnapshotWhenIdentityMatches() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }
        let attachmentIDBox = MutexBox<UUID?>(nil)
        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake(instance: "durable-1") },
            snapshot: {
                let id = attachmentIDBox.get() ?? UUID()
                return AttachmentTestFixtures.snapshot(
                    attachmentID: id,
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    instance: "durable-1"
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

        let intent = NestedAttachmentIntentDescriptor(
            providerKind: .herdr,
            reattachPolicy: .autoIfProviderInstanceMatches,
            endpointLocator: NestedAttachmentEndpointLocator(
                socketPath: AttachmentTestFixtures.endpoint.canonicalPath
            ),
            lastVerifiedProviderInstanceID: NestedProviderInstanceID(rawValue: "durable-1"),
            providerInstanceIdentityProofAvailable: true,
            lastVerifiedFileIdentity: AttachmentTestFixtures.endpoint.fileIdentity
        )
        let record = await coordinator.restoreFromIntent(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            intent: intent
        )
        attachmentIDBox.set(record.attachmentID)

        #expect(record.state == .live)
        #expect(record.providerInstanceID?.rawValue == "durable-1")
        #expect(record.providerInstanceIdentityProofAvailable)
        #expect(record.latestSnapshot != nil)
        #expect(record.pendingRestoreIntent == nil)
        #expect(await client.handshakeCount == 1)
        #expect(await client.snapshotCount == 1)
        #expect(
            NestedPluginWriterHandoff(directoryURL: handoffDir)
                .isHeld(hostStableSurfaceID: AttachmentTestFixtures.surfaceA)
        )
        // Fresh client path must not invent association rows from the intent.
        #expect(await client.associationStore().count == 0)
    }

    @Test func restoreCancellationWhenHostSurfaceCloses() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }

        let gate = AsyncGate()
        let client = StubNestedTopologyProviderClient(
            handshake: {
                await gate.wait()
                try Task.checkCancellation()
                return AttachmentTestFixtures.handshake(instance: "durable-1")
            },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    instance: "durable-1"
                )
            }
        )
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )

        let intent = NestedAttachmentIntentDescriptor(
            providerKind: .herdr,
            reattachPolicy: .autoIfProviderInstanceMatches,
            endpointLocator: NestedAttachmentEndpointLocator(
                socketPath: AttachmentTestFixtures.endpoint.canonicalPath
            ),
            lastVerifiedProviderInstanceID: NestedProviderInstanceID(rawValue: "durable-1"),
            providerInstanceIdentityProofAvailable: true,
            lastVerifiedFileIdentity: AttachmentTestFixtures.endpoint.fileIdentity
        )

        let restoreTask = Task {
            await coordinator.restoreFromIntent(
                hostWorkspaceID: AttachmentTestFixtures.workspaceA,
                hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                intent: intent
            )
        }

        var sawConnecting = false
        for _ in 0..<100 {
            if await coordinator.attachment(for: AttachmentTestFixtures.surfaceA)?.state == .connecting {
                sawConnecting = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sawConnecting)

        await coordinator.noteHostSurfaceClosed(hostStableSurfaceID: AttachmentTestFixtures.surfaceA)
        await gate.open()
        let record = await restoreTask.value
        #expect(record.state == .disconnected)
        #expect(await coordinator.attachment(for: AttachmentTestFixtures.surfaceA) == nil)
        #expect(
            NestedPluginWriterHandoff(directoryURL: handoffDir)
                .isHeld(hostStableSurfaceID: AttachmentTestFixtures.surfaceA) == false
        )
    }

    @Test func associationCacheNotRehydratedFromStaleSessionIntent() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }

        // Encode a malicious/stale JSON blob that includes association-like keys.
        // Decoding into NestedAttachmentIntentDescriptor must ignore them, and restore
        // must start from an empty association store.
        let dirtyJSON: [String: Any] = [
            "schema_version": 1,
            "provider_kind": "herdr",
            "reattach_policy": "auto_if_provider_instance_matches",
            "endpoint_locator": [
                "socket_path": AttachmentTestFixtures.endpoint.canonicalPath,
            ],
            "last_verified_provider_instance_id": "durable-1",
            "provider_instance_identity_proof_available": true,
            "last_verified_file_identity": [
                "device_id": 1,
                "inode": 2,
            ],
            "associations": [
                ["pane_id": "w1:p1", "session_id": "sess", "heuristic_satisfied": true],
            ],
            "latest_snapshot": ["workspaces": [["id": "w1"]]],
            "token": "secret-should-not-decode",
        ]
        let data = try JSONSerialization.data(withJSONObject: dirtyJSON)
        let intent = try JSONDecoder().decode(NestedAttachmentIntentDescriptor.self, from: data)
        #expect(intent.lastVerifiedProviderInstanceID?.rawValue == "durable-1")

        let reencoded = try JSONEncoder().encode(intent)
        let cleanObject = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        let keys = NestedAttachmentIntentDescriptor.collectJSONKeys(cleanObject)
        #expect(keys.contains("associations") == false)
        #expect(keys.contains("latest_snapshot") == false)
        #expect(keys.contains("token") == false)

        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake(instance: "durable-1") },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    instance: "durable-1"
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
        let record = await coordinator.restoreFromIntent(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            intent: intent
        )
        #expect(record.state == .live)
        #expect(await client.associationStore().count == 0)
    }

    @Test func confirmPendingRestoreRequiresExplicitOptIn() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }
        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake(instance: "durable-1") },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    instance: "durable-1"
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

        let intent = NestedAttachmentIntentDescriptor(
            providerKind: .herdr,
            reattachPolicy: .requireConfirmation,
            endpointLocator: NestedAttachmentEndpointLocator(
                socketPath: AttachmentTestFixtures.endpoint.canonicalPath
            ),
            lastVerifiedProviderInstanceID: NestedProviderInstanceID(rawValue: "durable-1"),
            providerInstanceIdentityProofAvailable: true,
            lastVerifiedFileIdentity: AttachmentTestFixtures.endpoint.fileIdentity
        )
        let pending = await coordinator.restoreFromIntent(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            intent: intent
        )
        #expect(pending.state == .disconnected)
        #expect(pending.pendingRestoreIntent != nil)

        do {
            _ = try await coordinator.confirmPendingRestore(
                hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                authorization: nil
            )
            Issue.record("expected opt-in required")
        } catch let error as NestedAttachmentError {
            #expect(error == .optInRequired)
        }

        let live = try await coordinator.confirmPendingRestore(
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            authorization: .userConfirmed
        )
        #expect(live.state == .live)
        #expect(live.latestSnapshot != nil)
    }
}
