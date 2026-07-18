@testable import CmuxTerminalBackend
import Foundation
import Testing

@Suite("Persistent service handoff commands")
struct BackendServiceHandoffCommandTests {
    private let sourceBuildID = String(repeating: "1", count: 64)
    private let targetBuildID = String(repeating: "2", count: 64)

    @Test("service coordinator registers with its dedicated least-privilege role")
    func coordinatorRegistration() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let identity = try #require(
            BackendClientRegistrationIdentity(
                clientUUID: UUID(),
                processInstanceUUID: UUID()
            )
        )
        let connectionID = UUID()

        let task = Task {
            try await client.registerClient(
                supportedRange: 9 ... 9,
                identity: identity,
                kind: .serviceCoordinator
            )
        }
        let request = try object(await transport.nextSent())
        #expect(request["cmd"] as? String == "register-client")
        #expect(request["client_kind"] as? String == "service-coordinator")
        await transport.enqueue(try response(
            to: request,
            data: [
                "protocol": 9,
                "connection_id": connectionID.uuidString,
                "client_uuid": identity.clientUUID.uuidString,
                "process_instance_uuid": identity.processInstanceUUID.uuidString,
                "client_kind": "service-coordinator",
                "role": "service-coordinator",
                "topology_lease_id": NSNull(),
                "topology_lease_generation": NSNull(),
            ]
        ))

        let registration = try await task.value
        #expect(registration.connectionID == connectionID)
        #expect(registration.clientKind == .serviceCoordinator)
        #expect(registration.role == .serviceCoordinator)
        #expect(registration.topologyMutationLease == nil)
        await client.close()
    }

    @Test("prepared permit decodes every replacement fence")
    func preparePermit() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let connectionID = UUID()
        let daemonID = UUID()
        let sessionID = UUID()
        let capability = String(repeating: "a", count: 64)

        let task = Task {
            try await client.prepareServiceHandoff(targetBuildID: targetBuildID)
        }
        let request = try object(await transport.nextSent())
        #expect(request["cmd"] as? String == "prepare-service-handoff")
        #expect(request["target_build_id"] as? String == targetBuildID)
        await transport.enqueue(try response(
            to: request,
            data: [
                "status": "prepared",
                "capability": capability,
                "owner_connection_id": connectionID.uuidString,
                "daemon_instance_id": daemonID.uuidString,
                "session_id": sessionID.uuidString,
                "session": "cmux",
                "source_build_id": sourceBuildID,
                "target_build_id": targetBuildID,
                "topology_revision": 17,
                "canonical_topology_revision": 13,
                "durable_storage": [
                    "state": "healthy",
                    "incident_id": NSNull(),
                    "failure_phase": NSNull(),
                    "failure_resolution": NSNull(),
                    "unresolved_mutation": false,
                    "unresolved_launch_attempts": 0,
                ],
            ]
        ))

        guard case .prepared(let permit) = try await task.value else {
            Issue.record("expected a prepared permit")
            return
        }
        #expect(permit.capability == capability)
        #expect(permit.ownerConnectionID == connectionID)
        #expect(permit.authority == BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: daemonID),
            sessionID: SessionID(rawValue: sessionID)
        ))
        #expect(permit.session == "cmux")
        #expect(permit.sourceBuildID == sourceBuildID)
        #expect(permit.targetBuildID == targetBuildID)
        #expect(permit.topologyRevision == 17)
        #expect(permit.canonicalTopologyRevision == 13)
        #expect(permit.durableStorage.state == .healthy)
        #expect(permit.durableStorage.unresolvedMutation == false)
        #expect(permit.durableStorage.unresolvedLaunchAttempts == 0)
        await client.close()
    }

    @Test("not-idle preparation preserves content-free blocker counts")
    func deferredPreparation() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()

        let task = Task {
            try await client.prepareServiceHandoff(targetBuildID: targetBuildID)
        }
        let request = try object(await transport.nextSent())
        await transport.enqueue(try response(
            to: request,
            data: [
                "status": "deferred-not-idle",
                "blockers": blockerPayload(canonicalSurfaces: 2),
            ]
        ))

        guard case .deferredNotIdle(let blockers) = try await task.value else {
            Issue.record("expected deferred-not-idle")
            return
        }
        #expect(blockers.canonicalSurfaces == 2)
        #expect(blockers.rendererWorkers == 0)
        #expect(blockers.durableStorageDegraded == false)
        await client.close()
    }

    @Test("cancellation echoes the one-shot connection and build-bound permit")
    func cancellationRequest() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let permit = BackendServiceHandoffPermit(
            capability: String(repeating: "b", count: 64),
            ownerConnectionID: UUID(),
            authority: BackendAuthority(
                daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
                sessionID: SessionID(rawValue: UUID())
            ),
            session: "cmux",
            sourceBuildID: sourceBuildID,
            targetBuildID: targetBuildID,
            topologyRevision: 4,
            canonicalTopologyRevision: 3,
            durableStorage: BackendServiceDurableStorageStatus(
                state: .healthy,
                incidentID: nil,
                failurePhase: nil,
                failureResolution: nil,
                unresolvedMutation: false,
                unresolvedLaunchAttempts: 0
            )
        )

        let task = Task { try await client.cancelServiceHandoff(permit) }
        let request = try object(await transport.nextSent())
        #expect(request["cmd"] as? String == "cancel-service-handoff")
        #expect(request["capability"] as? String == permit.capability)
        #expect(request["source_build_id"] as? String == sourceBuildID)
        #expect(request["target_build_id"] as? String == targetBuildID)
        await transport.enqueue(try response(
            to: request,
            data: ["status": "cancelled"]
        ))
        try await task.value
        await client.close()
    }

    private func blockerPayload(canonicalSurfaces: Int) -> [String: Any] {
        [
            "canonical_surfaces": canonicalSurfaces,
            "pending_terminal_launches": 0,
            "presentations": 0,
            "projection_states": 0,
            "terminal_authorities": 0,
            "renderer_presentations": 0,
            "renderer_workers": 0,
            "pending_renderer_removals": 0,
            "renderer_release_routes": 0,
            "browser_runtime": false,
            "frontend_native_browser_runtimes": 0,
            "remote_external_producer_runtimes": 0,
            "sidebar_plugin_runtime": false,
            "agent_records": 0,
            "unresolved_durable_mutation": false,
            "unresolved_launch_attempts": 0,
            "durable_storage_degraded": false,
        ]
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func response(to request: [String: Any], data: [String: Any]) throws -> Data {
        try encodedJSON([
            "id": try #require(request["id"] as? NSNumber).uint64Value,
            "ok": true,
            "data": data,
        ])
    }
}
