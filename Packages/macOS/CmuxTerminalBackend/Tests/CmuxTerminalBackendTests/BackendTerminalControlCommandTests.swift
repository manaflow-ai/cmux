@testable import CmuxTerminalBackend
import Foundation
import Testing

@Suite("Protocol-v9 terminal control commands")
struct BackendTerminalControlCommandTests {
    @Test("registration, lease, typed input, geometry, and status preserve exact fences")
    func completeWireContract() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let clientUUID = try #require(
            UUID(uuidString: "11111111-1111-4111-8111-111111111111")
        )
        let processUUID = try #require(
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")
        )
        let connectionID = try #require(
            UUID(uuidString: "33333333-3333-4333-8333-333333333333")
        )
        let identity = try #require(
            BackendClientRegistrationIdentity(
                clientUUID: clientUUID,
                processInstanceUUID: processUUID
            )
        )

        let registrationTask = Task {
            try await client.registerClient(supportedRange: 9 ... 9, identity: identity)
        }
        let registrationRequest = try terminalControlRequest(await transport.nextSent())
        #expect(registrationRequest["cmd"] as? String == "register-client")
        #expect(try terminalControlUInt64(registrationRequest, "protocol_min") == 9)
        #expect(try terminalControlUInt64(registrationRequest, "protocol_max") == 9)
        #expect(registrationRequest["client_uuid"] as? String == clientUUID.uuidString.lowercased())
        #expect(
            registrationRequest["process_instance_uuid"] as? String
                == processUUID.uuidString.lowercased()
        )
        await transport.enqueue(try terminalControlResponse(
            to: registrationRequest,
            data: [
                "protocol": 9,
                "connection_id": connectionID.uuidString,
                "client_uuid": clientUUID.uuidString,
                "process_instance_uuid": processUUID.uuidString,
            ]
        ))
        #expect(try await registrationTask.value.connectionID == connectionID)

        let surfaceID = SurfaceID(
            rawValue: try #require(
                UUID(uuidString: "44444444-4444-4444-8444-444444444444")
            )
        )
        let presentationID = PresentationID(
            rawValue: try #require(
                UUID(uuidString: "55555555-5555-4555-8555-555555555555")
            )
        )
        let inputLeaseID = try #require(
            UUID(uuidString: "66666666-6666-4666-8666-666666666666")
        )
        let leaseTask = Task {
            try await client.acquireTerminalLease(
                kind: .input,
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 7,
                ttlMilliseconds: 5_000
            )
        }
        let leaseRequest = try terminalControlRequest(await transport.nextSent())
        #expect(leaseRequest["cmd"] as? String == "acquire-terminal-lease")
        #expect(leaseRequest["kind"] as? String == "input")
        #expect(leaseRequest["surface_uuid"] as? String == surfaceID.description)
        #expect(leaseRequest["presentation_id"] as? String == presentationID.description)
        #expect(try terminalControlUInt64(leaseRequest, "presentation_generation") == 7)
        #expect(try terminalControlUInt64(leaseRequest, "ttl_ms") == 5_000)
        await transport.enqueue(try terminalControlResponse(
            to: leaseRequest,
            data: [
                "kind": "input",
                "surface_uuid": surfaceID.description,
                "presentation_id": presentationID.description,
                "presentation_generation": 7,
                "lease_id": inputLeaseID.uuidString,
                "lease_generation": 3,
                "revocation_sequence": 0,
                "expires_at_ms": 90_000,
                "next_sequence": 4,
                "next_global_input_sequence": 22,
                "migrated_from_legacy": true,
            ]
        ))
        let inputLease = BackendTerminalLease(
            connectionID: connectionID,
            response: try await leaseTask.value
        )

        let geometryLeaseID = UUID()
        let geometryLeaseTask = Task {
            try await client.acquireTerminalLease(
                kind: .geometry,
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: 7,
                ttlMilliseconds: 8_000
            )
        }
        let geometryLeaseRequest = try terminalControlRequest(await transport.nextSent())
        #expect(geometryLeaseRequest["kind"] as? String == "geometry")
        await transport.enqueue(try terminalControlResponse(
            to: geometryLeaseRequest,
            data: [
                "kind": "geometry",
                "surface_uuid": surfaceID.description,
                "presentation_id": presentationID.description,
                "presentation_generation": 7,
                "lease_id": geometryLeaseID.uuidString,
                "lease_generation": 8,
                "revocation_sequence": 2,
                "expires_at_ms": 91_000,
                "next_sequence": 8,
                "migrated_from_legacy": false,
            ]
        ))
        let geometryLease = BackendTerminalLease(
            connectionID: connectionID,
            response: try await geometryLeaseTask.value
        )

        let inputRequestID = try #require(
            UUID(uuidString: "77777777-7777-4777-8777-777777777777")
        )
        let inputTask = Task {
            try await client.sendTerminalInput(
                lease: inputLease,
                sequence: 4,
                requestID: inputRequestID,
                input: .namedKey("ctrl+shift+p")
            )
        }
        let inputRequest = try terminalControlRequest(await transport.nextSent())
        #expect(inputRequest["cmd"] as? String == "terminal-input")
        #expect(try terminalControlUInt64(inputRequest, "sequence") == 4)
        #expect(inputRequest["request_id"] as? String == inputRequestID.uuidString.lowercased())
        let input = try #require(inputRequest["input"] as? [String: Any])
        #expect(input["type"] as? String == "named-key")
        #expect(input["key"] as? String == "ctrl+shift+p")
        await transport.enqueue(try terminalControlResponse(
            to: inputRequest,
            data: [
                "request_id": inputRequestID.uuidString,
                "status": "applied",
                "kind": "input",
                "sequence": 4,
                "ordered_input_sequence": 22,
                "lease_generation": 3,
                "replayed": false,
                "encoded_bytes": 3,
                "lease_revoked": false,
            ]
        ))
        #expect(try await inputTask.value.encodedBytes == 3)

        let delegateClientUUID = UUID()
        let delegateProcessUUID = UUID()
        let delegationID = UUID()
        let delegationTask = Task {
            try await client.grantTerminalInputDelegation(
                lease: inputLease,
                delegateClientUUID: delegateClientUUID,
                ttlMilliseconds: 2_000,
                scopes: [.text, .key]
            )
        }
        let delegationRequest = try terminalControlRequest(await transport.nextSent())
        #expect(delegationRequest["cmd"] as? String == "grant-terminal-input-delegation")
        #expect(
            delegationRequest["delegate_client_uuid"] as? String
                == delegateClientUUID.uuidString.lowercased()
        )
        #expect(delegationRequest["scopes"] as? [String] == ["key", "text"])
        await transport.enqueue(try terminalControlResponse(
            to: delegationRequest,
            data: [
                "surface_uuid": surfaceID.description,
                "delegation_id": delegationID.uuidString,
                "delegation_generation": 4,
                "owner_lease_generation": 3,
                "delegate_client_uuid": delegateClientUUID.uuidString,
                "delegate_process_instance_uuid": delegateProcessUUID.uuidString,
                "expires_at_ms": 92_000,
                "scopes": ["text", "key"],
                "next_sequence": 1,
            ]
        ))
        let delegation = try await delegationTask.value

        let delegatedRequestID = UUID()
        let groupID = UUID()
        let delegatedTask = Task {
            try await client.sendDelegatedTerminalInput(
                delegation: delegation,
                sequence: 1,
                requestID: delegatedRequestID,
                input: .text("atomic paste", paste: true),
                group: BackendTerminalInputGroup(id: groupID, index: 0, end: true)
            )
        }
        let delegatedRequest = try terminalControlRequest(await transport.nextSent())
        #expect(delegatedRequest["cmd"] as? String == "terminal-delegated-input")
        #expect(delegatedRequest["input_group_id"] as? String == groupID.uuidString.lowercased())
        #expect(try terminalControlUInt64(delegatedRequest, "input_group_index") == 0)
        #expect(delegatedRequest["input_group_end"] as? Bool == true)
        await transport.enqueue(try terminalControlResponse(
            to: delegatedRequest,
            data: [
                "request_id": delegatedRequestID.uuidString,
                "status": "applied",
                "kind": "input",
                "sequence": 1,
                "ordered_input_sequence": 23,
                "lease_generation": 3,
                "replayed": false,
                "encoded_bytes": 12,
                "lease_revoked": false,
            ]
        ))
        #expect(try await delegatedTask.value.orderedInputSequence == 23)

        let revokeTask = Task {
            try await client.revokeTerminalInputDelegation(
                lease: inputLease,
                delegation: delegation
            )
        }
        let revokeRequest = try terminalControlRequest(await transport.nextSent())
        #expect(revokeRequest["cmd"] as? String == "revoke-terminal-input-delegation")
        #expect(revokeRequest["delegation_id"] as? String == delegationID.uuidString.lowercased())
        await transport.enqueue(try terminalControlResponse(to: revokeRequest, data: [:]))
        try await revokeTask.value

        let geometryRequestID = try #require(
            UUID(uuidString: "88888888-8888-4888-8888-888888888888")
        )
        let geometryTask = Task {
            try await client.sendTerminalGeometry(
                lease: geometryLease,
                sequence: 8,
                requestID: geometryRequestID,
                columns: 132,
                rows: 43
            )
        }
        let geometryRequest = try terminalControlRequest(await transport.nextSent())
        #expect(geometryRequest["cmd"] as? String == "terminal-geometry")
        #expect(try terminalControlUInt64(geometryRequest, "sequence") == 8)
        #expect(try terminalControlUInt64(geometryRequest, "cols") == 132)
        #expect(try terminalControlUInt64(geometryRequest, "rows") == 43)
        await transport.enqueue(try terminalControlResponse(
            to: geometryRequest,
            data: [
                "request_id": geometryRequestID.uuidString,
                "status": "applied",
                "kind": "geometry",
                "sequence": 8,
                "lease_generation": 8,
                "replayed": false,
                "cols": 132,
                "rows": 43,
                "changed": true,
                "lease_revoked": false,
            ]
        ))
        #expect(try await geometryTask.value.changed == true)

        let statusTask = Task {
            try await client.terminalRequestStatus(
                surfaceID: surfaceID,
                requestID: inputRequestID
            )
        }
        let statusRequest = try terminalControlRequest(await transport.nextSent())
        #expect(statusRequest["cmd"] as? String == "terminal-request-status")
        await transport.enqueue(try terminalControlResponse(
            to: statusRequest,
            data: [
                "request_id": inputRequestID.uuidString,
                "status": "unknown",
            ]
        ))
        #expect(try await statusTask.value.status == .unknown)

        let acknowledgementTask = Task {
            try await client.acknowledgeTerminalRequest(
                surfaceID: surfaceID,
                requestID: inputRequestID
            )
        }
        let acknowledgementRequest = try terminalControlRequest(await transport.nextSent())
        #expect(
            acknowledgementRequest["cmd"] as? String
                == "acknowledge-terminal-request"
        )
        #expect(
            acknowledgementRequest["request_id"] as? String
                == inputRequestID.uuidString.lowercased()
        )
        await transport.enqueue(try terminalControlResponse(
            to: acknowledgementRequest,
            data: [
                "request_id": inputRequestID.uuidString,
                "acknowledged": true,
            ]
        ))
        #expect(try await acknowledgementTask.value)
        await client.close()
    }

    @Test("pixel mouse input resolves to bounded renderer-owned cells")
    func cellMouseResolution() throws {
        let padding = BackendRendererPadding(left: 10, top: 20, right: 10, bottom: 20)
        let inside = try #require(BackendTerminalCellMouseEvent(
            action: .motion,
            x: 43,
            y: 58,
            columns: 80,
            rows: 24,
            cellWidth: 8,
            cellHeight: 16,
            padding: padding
        ))
        #expect(inside.column == 4)
        #expect(inside.row == 2)

        let padded = try #require(BackendTerminalCellMouseEvent(
            action: .press,
            button: .left,
            x: 1,
            y: 2,
            columns: 80,
            rows: 24,
            cellWidth: 8,
            cellHeight: 16,
            padding: padding
        ))
        #expect(padded.column == 0)
        #expect(padded.row == 0)

        let beyondEdge = try #require(BackendTerminalCellMouseEvent(
            action: .motion,
            x: Double.greatestFiniteMagnitude,
            y: Double.greatestFiniteMagnitude,
            columns: 80,
            rows: 24,
            cellWidth: 8,
            cellHeight: 16,
            padding: padding
        ))
        #expect(beyondEdge.column == 79)
        #expect(beyondEdge.row == 23)
        #expect(BackendTerminalCellMouseEvent(
            action: .motion,
            x: .nan,
            y: 0,
            columns: 80,
            rows: 24,
            cellWidth: 8,
            cellHeight: 16,
            padding: padding
        ) == nil)
    }
}

private func terminalControlRequest(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func terminalControlResponse(
    to request: [String: Any],
    data: [String: Any]
) throws -> Data {
    try encodedJSON([
        "id": try terminalControlUInt64(request, "id"),
        "ok": true,
        "data": data,
    ])
}

private func terminalControlUInt64(_ object: [String: Any], _ key: String) throws -> UInt64 {
    try #require(object[key] as? NSNumber).uint64Value
}
