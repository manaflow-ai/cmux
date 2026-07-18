public import Foundation

public extension BackendProtocolClient {
    /// Registers the stable logical client and its least-privilege purpose on this connection.
    ///
    /// - Parameters:
    ///   - supportedRange: The terminal-control protocol versions accepted by the caller.
    ///   - identity: The logical client and process-launch identity bound to this connection.
    ///   - kind: The server-recognized purpose used to issue a connection role.
    /// - Returns: The server-selected protocol, echoed identity, and issued role.
    /// - Throws: A transport, protocol, or registration validation error.
    func registerClient(
        supportedRange: ClosedRange<UInt32>,
        identity: BackendClientRegistrationIdentity,
        kind: BackendRegisteredClientKind = .swiftShell
    ) async throws -> BackendClientRegistration {
        try await call(
            command: "register-client",
            parameters: [
                "protocol_min": .unsignedInteger(UInt64(supportedRange.lowerBound)),
                "protocol_max": .unsignedInteger(UInt64(supportedRange.upperBound)),
                "client_kind": .string(kind.rawValue),
                "client_uuid": .string(identity.clientUUID.uuidString.lowercased()),
                "process_instance_uuid": .string(
                    identity.processInstanceUUID.uuidString.lowercased()
                ),
            ],
            as: BackendClientRegistration.self
        )
    }

    /// Acquires one independent operation lane for a visible presentation.
    internal func acquireTerminalLease(
        kind: BackendTerminalLeaseKind,
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        ttlMilliseconds: UInt64
    ) async throws -> BackendTerminalLeaseResponse {
        try await call(
            command: "acquire-terminal-lease",
            parameters: [
                "kind": .string(kind.rawValue),
                "surface_uuid": .string(surfaceID.description),
                "presentation_id": .string(presentationID.description),
                "presentation_generation": .unsignedInteger(presentationGeneration),
                "ttl_ms": .unsignedInteger(ttlMilliseconds),
            ],
            as: BackendTerminalLeaseResponse.self
        )
    }

    /// Renews one exact connection-owned lane without changing generation.
    internal func renewTerminalLease(
        _ lease: BackendTerminalLease,
        ttlMilliseconds: UInt64
    ) async throws -> BackendTerminalLeaseResponse {
        var parameters = lease.referenceParameters
        parameters["kind"] = .string(lease.kind.rawValue)
        parameters["ttl_ms"] = .unsignedInteger(ttlMilliseconds)
        return try await call(
            command: "renew-terminal-lease",
            parameters: parameters,
            as: BackendTerminalLeaseResponse.self
        )
    }

    /// Releases one exact connection-owned terminal lease.
    func releaseTerminalLease(_ lease: BackendTerminalLease) async throws {
        var parameters = lease.referenceParameters
        parameters["kind"] = .string(lease.kind.rawValue)
        let _: BackendEmptyResponse = try await call(
            command: "release-terminal-lease",
            parameters: parameters,
            as: BackendEmptyResponse.self
        )
    }

    internal func transferTerminalLease(
        _ lease: BackendTerminalLease,
        targetClientUUID: UUID,
        targetPresentationID: PresentationID,
        targetPresentationGeneration: UInt64,
        ttlMilliseconds: UInt64
    ) async throws -> BackendTerminalLeaseResponse {
        var parameters = lease.referenceParameters
        parameters["kind"] = .string(lease.kind.rawValue)
        parameters["target_client_uuid"] = .string(targetClientUUID.uuidString.lowercased())
        parameters["target_presentation_id"] = .string(targetPresentationID.description)
        parameters["target_presentation_generation"] = .unsignedInteger(
            targetPresentationGeneration
        )
        parameters["ttl_ms"] = .unsignedInteger(ttlMilliseconds)
        return try await call(
            command: "transfer-terminal-lease",
            parameters: parameters,
            as: BackendTerminalLeaseResponse.self
        )
    }

    internal func grantTerminalInputDelegation(
        lease: BackendTerminalLease,
        delegateClientUUID: UUID,
        ttlMilliseconds: UInt64,
        scopes: Set<BackendTerminalAutomationInputScope>
    ) async throws -> BackendTerminalInputDelegation {
        var parameters = lease.referenceParameters
        parameters["delegate_client_uuid"] = .string(
            delegateClientUUID.uuidString.lowercased()
        )
        parameters["ttl_ms"] = .unsignedInteger(ttlMilliseconds)
        parameters["scopes"] = .array(scopes.sorted { $0.rawValue < $1.rawValue }.map {
            .string($0.rawValue)
        })
        return try await call(
            command: "grant-terminal-input-delegation",
            parameters: parameters,
            as: BackendTerminalInputDelegation.self
        )
    }

    internal func revokeTerminalInputDelegation(
        lease: BackendTerminalLease,
        delegation: BackendTerminalInputDelegation
    ) async throws {
        var parameters = lease.referenceParameters
        parameters["delegation_id"] = .string(
            delegation.delegationID.uuidString.lowercased()
        )
        parameters["delegation_generation"] = .unsignedInteger(
            delegation.delegationGeneration
        )
        let _: BackendEmptyResponse = try await call(
            command: "revoke-terminal-input-delegation",
            parameters: parameters,
            as: BackendEmptyResponse.self
        )
    }

    /// Sends one typed, ordered, caller-idempotent terminal input.
    func sendTerminalInput(
        lease: BackendTerminalLease,
        sequence: UInt64,
        requestID: UUID,
        input: BackendTerminalControlInput,
        group: BackendTerminalInputGroup? = nil
    ) async throws -> BackendTerminalOperationReceipt {
        var parameters = lease.referenceParameters
        parameters["sequence"] = .unsignedInteger(sequence)
        parameters["request_id"] = .string(requestID.uuidString.lowercased())
        parameters["input"] = input.jsonValue
        if let group {
            parameters["input_group_id"] = .string(group.id.uuidString.lowercased())
            parameters["input_group_index"] = .unsignedInteger(UInt64(group.index))
            parameters["input_group_end"] = .bool(group.end)
        }
        return try await call(
            command: "terminal-input",
            parameters: parameters,
            as: BackendTerminalOperationReceipt.self
        )
    }

    /// Sends input under a bounded automation delegation. No presentation or
    /// geometry authority is implied by the stable delegate UUID.
    func sendDelegatedTerminalInput(
        delegation: BackendTerminalInputDelegation,
        sequence: UInt64,
        requestID: UUID,
        input: BackendTerminalControlInput,
        group: BackendTerminalInputGroup? = nil
    ) async throws -> BackendTerminalOperationReceipt {
        var parameters: [String: BackendJSONValue] = [
            "surface_uuid": .string(delegation.surfaceID.description),
            "delegation_id": .string(delegation.delegationID.uuidString.lowercased()),
            "delegation_generation": .unsignedInteger(delegation.delegationGeneration),
            "sequence": .unsignedInteger(sequence),
            "request_id": .string(requestID.uuidString.lowercased()),
            "input": input.jsonValue,
        ]
        if let group {
            parameters["input_group_id"] = .string(group.id.uuidString.lowercased())
            parameters["input_group_index"] = .unsignedInteger(UInt64(group.index))
            parameters["input_group_end"] = .bool(group.end)
        }
        return try await call(
            command: "terminal-delegated-input",
            parameters: parameters,
            as: BackendTerminalOperationReceipt.self
        )
    }

    /// Sends one independently ordered, caller-idempotent grid mutation.
    func sendTerminalGeometry(
        lease: BackendTerminalLease,
        sequence: UInt64,
        requestID: UUID,
        columns: UInt16,
        rows: UInt16
    ) async throws -> BackendTerminalOperationReceipt {
        var parameters = lease.referenceParameters
        parameters["sequence"] = .unsignedInteger(sequence)
        parameters["request_id"] = .string(requestID.uuidString.lowercased())
        parameters["cols"] = .unsignedInteger(UInt64(columns))
        parameters["rows"] = .unsignedInteger(UInt64(rows))
        return try await call(
            command: "terminal-geometry",
            parameters: parameters,
            as: BackendTerminalOperationReceipt.self
        )
    }

    /// Looks up a prior operation receipt after reconnecting with the same client UUID.
    func terminalRequestStatus(
        surfaceID: SurfaceID,
        requestID: UUID
    ) async throws -> BackendTerminalOperationReceipt {
        try await call(
            command: "terminal-request-status",
            parameters: [
                "surface_uuid": .string(surfaceID.description),
                "request_id": .string(requestID.uuidString.lowercased()),
            ],
            as: BackendTerminalOperationReceipt.self
        )
    }

    /// Releases one durable receipt after the caller has made its result definitive.
    func acknowledgeTerminalRequest(
        surfaceID: SurfaceID,
        requestID: UUID
    ) async throws -> Bool {
        let response: BackendTerminalRequestAcknowledgement = try await call(
            command: "acknowledge-terminal-request",
            parameters: [
                "surface_uuid": .string(surfaceID.description),
                "request_id": .string(requestID.uuidString.lowercased()),
            ],
            as: BackendTerminalRequestAcknowledgement.self
        )
        guard response.requestID == requestID else {
            throw BackendProtocolError.malformedMessage
        }
        return response.acknowledged
    }
}

private struct BackendTerminalRequestAcknowledgement: Decodable {
    let requestID: UUID
    let acknowledged: Bool

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case acknowledged
    }
}

private extension BackendTerminalLease {
    var referenceParameters: [String: BackendJSONValue] {
        [
            "surface_uuid": .string(surfaceID.description),
            "presentation_id": .string(presentationID.description),
            "presentation_generation": .unsignedInteger(presentationGeneration),
            "lease_id": .string(leaseID.uuidString.lowercased()),
            "lease_generation": .unsignedInteger(leaseGeneration),
        ]
    }
}
