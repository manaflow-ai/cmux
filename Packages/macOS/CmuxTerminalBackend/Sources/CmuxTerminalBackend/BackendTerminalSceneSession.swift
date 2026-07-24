public import Foundation

/// One-time binary endpoint issued by the exact cmuxd connection that authorized it.
public struct BackendTerminalSceneEndpointReceipt: Decodable, Equatable, Sendable {
    public let path: String
    public let token: String
}

/// Fail-closed validation errors for one dedicated semantic-scene connection.
public enum BackendTerminalSceneError: Error, Equatable, Sendable {
    case alreadyAttached
    case notAttached
    case missingExactPeerExpectation
    case incompatibleBackend
    case surfaceNotFound(SurfaceID)
    case surfaceIsNotTerminal(SurfaceID)
    case invalidEndpointReceipt
    case invalidRendererConfiguration
    case inputTooLarge(maximumBytes: Int)
}

/// One exact-peer, protocol-v9 control connection for a mobile semantic scene.
///
/// cmuxd sends scene bytes over the authenticated one-shot endpoint returned by
/// ``attach(surfaceID:presentationID:presentationGeneration:rendererConfig:)``.
/// This JSON connection remains open only to carry the same text delegation
/// used by the compatibility lane. It never owns topology or terminal leases.
public actor BackendTerminalSceneSession {
    public static let capability = "terminal-semantic-scene-v1"
    public static let maximumRendererConfigBytes = 256 * 1_024
    public static let maximumInputBytes = 16 * 1_024

    private static let handshakePolicy = BackendHandshakePolicy(
        supportedRange: 9 ... 9,
        minimumReadWriteProtocol: 9,
        requiredCapabilities: Set([
            capability,
            "canonical-topology-snapshot-v1",
            "stable-entity-uuid-v1",
        ]).union(BackendHandshakePolicy.terminalControlV9Capabilities)
    )

    private struct ResolvedSurface: Sendable {
        let handle: UInt64
        let surfaceID: SurfaceID
    }

    private let transport: any BackendPeerIdentityTransport
    private let client: BackendProtocolClient
    private let expectation: BackendCanonicalSessionExpectation
    private let registrationIdentity: BackendClientRegistrationIdentity
    private let inputAuthority: any BackendTerminalCompatibilityInputAuthority

    private var resolvedSurface: ResolvedSurface?
    private var registration: BackendClientRegistration?
    private var inputDelegation: BackendTerminalInputDelegation?
    private var nextInputSequence: UInt64?
    private var inputOperationActive = false
    private var inputOperationWaiters: [CheckedContinuation<Void, Never>] = []
    private var attached = false
    private var finished = false

    public init(
        transport: any BackendPeerIdentityTransport,
        expectation: BackendCanonicalSessionExpectation,
        registrationIdentity: BackendClientRegistrationIdentity,
        inputAuthority: any BackendTerminalCompatibilityInputAuthority
    ) {
        self.transport = transport
        self.expectation = expectation
        self.registrationIdentity = registrationIdentity
        self.inputAuthority = inputAuthority
        client = BackendProtocolClient(transport: transport, eventCapacity: 1)
    }

    /// Authenticates the daemon, resolves a stable surface ID, and opens one scene endpoint.
    public func attach(
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        rendererConfig: Data,
        focused: Bool = true,
        cursorBlinkVisible: Bool = true
    ) async throws -> BackendTerminalSceneEndpointReceipt {
        guard !attached else { throw BackendTerminalSceneError.alreadyAttached }
        guard !finished else { throw BackendProtocolError.connectionClosed }
        guard let expectedPeer = expectation.peerIdentity else {
            throw BackendTerminalSceneError.missingExactPeerExpectation
        }
        guard presentationID.rawValue != Self.nilUUID,
              presentationGeneration > 0,
              !rendererConfig.isEmpty,
              rendererConfig.count <= Self.maximumRendererConfigBytes else {
            throw BackendTerminalSceneError.invalidRendererConfiguration
        }

        do {
            try await client.connect()
            let actualPeer = try await transport.peerIdentity()
            guard actualPeer == expectedPeer else {
                throw BackendCanonicalSessionError.unexpectedPeerIdentity(
                    expected: expectedPeer,
                    actual: actualPeer
                )
            }

            let identify = try await client.identify()
            try validateIdentity(identify)
            let compatibility = try Self.handshakePolicy.validate(identify)
            guard case .readWrite(let readWrite) = compatibility,
                  readWrite.negotiatedProtocol == 9 else {
                throw BackendTerminalSceneError.incompatibleBackend
            }
            try await client.installCompatibility(compatibility)

            let registration = try await client.registerClient(
                supportedRange: 9 ... 9,
                identity: registrationIdentity,
                kind: .mobileScene
            )
            guard registration.protocolVersion == 9,
                  registration.clientUUID == registrationIdentity.clientUUID,
                  registration.processInstanceUUID == registrationIdentity.processInstanceUUID,
                  registration.clientKind == .mobileScene,
                  registration.role == .trustedInputDelegate,
                  registration.topologyMutationLease == nil else {
                throw BackendTerminalControlError.registrationIdentityMismatch
            }
            self.registration = registration

            let topology = try await client.topologySnapshot()
            guard topology.authority == identify.authority else {
                throw BackendCanonicalSessionError.snapshotAuthorityMismatch(
                    expected: identify.authority,
                    actual: topology.authority
                )
            }
            let resolved = try resolve(surfaceID, in: topology.topology)
            resolvedSurface = resolved

            let receipt: BackendTerminalSceneEndpointReceipt = try await client.call(
                command: "attach-terminal-scene",
                parameters: [
                    "surface": .unsignedInteger(resolved.handle),
                    "presentation_id": .string(presentationID.description),
                    "presentation_generation": .unsignedInteger(presentationGeneration),
                    "renderer_config": .string(rendererConfig.base64EncodedString()),
                    "focused": .bool(focused),
                    "cursor_blink_visible": .bool(cursorBlinkVisible),
                ]
            )
            guard receipt.path.utf8.count > 1,
                  receipt.path.utf8.count < 104,
                  receipt.path.first == "/",
                  receipt.token.utf8.count == 43,
                  Data(base64URLEncoded: receipt.token)?.count == 32 else {
                throw BackendTerminalSceneError.invalidEndpointReceipt
            }
            attached = true
            return receipt
        } catch {
            await fail()
            throw error
        }
    }

    /// Sends text through the canonical frontend's connection-bound delegation.
    public func sendInput(_ text: String) async throws {
        let data = Data(text.utf8)
        try await sendInput(.text(text, paste: false), encodedByteCount: data.count)
    }

    /// Sends exact terminal bytes through the canonical frontend's delegation.
    public func sendInput(_ data: Data) async throws {
        try await sendInput(.bytes(data, paste: false), encodedByteCount: data.count)
    }

    private func sendInput(
        _ input: BackendTerminalControlInput,
        encodedByteCount: Int
    ) async throws {
        await beginInputOperation()
        defer { endInputOperation() }
        try Task.checkCancellation()
        guard attached, !finished, let resolvedSurface, registration != nil else {
            throw BackendTerminalSceneError.notAttached
        }
        guard encodedByteCount <= Self.maximumInputBytes else {
            throw BackendTerminalSceneError.inputTooLarge(maximumBytes: Self.maximumInputBytes)
        }
        guard encodedByteCount > 0 else { return }

        do {
            let previous = inputDelegation
            let authorized = try await inputAuthority.authorizeTerminalCompatibilityInput(
                surfaceID: resolvedSurface.surfaceID,
                delegateIdentity: registrationIdentity,
                replacing: previous
            )
            guard !finished, attached else {
                try? await inputAuthority.revokeTerminalCompatibilityInput(
                    surfaceID: resolvedSurface.surfaceID,
                    delegateIdentity: registrationIdentity,
                    delegation: authorized
                )
                throw BackendProtocolError.connectionClosed
            }
            inputDelegation = authorized
            try validateInputDelegation(authorized, surfaceID: resolvedSurface.surfaceID)
            let sameAuthority = previous.map {
                $0.delegationID == authorized.delegationID
                    && $0.delegationGeneration == authorized.delegationGeneration
            } ?? false
            if sameAuthority {
                guard previous == authorized, nextInputSequence != nil else {
                    throw BackendProtocolError.malformedMessage
                }
            } else {
                nextInputSequence = authorized.nextSequence
            }
            guard let sequence = nextInputSequence else {
                throw BackendProtocolError.malformedMessage
            }

            let requestID = UUID()
            let receipt = try await client.sendDelegatedTerminalInput(
                delegation: authorized,
                sequence: sequence,
                requestID: requestID,
                input: input
            )
            try validateInputReceipt(
                receipt,
                requestID: requestID,
                sequence: sequence,
                leaseGeneration: authorized.ownerLeaseGeneration,
                encodedBytes: UInt64(encodedByteCount)
            )
            guard try await client.acknowledgeTerminalRequest(
                surfaceID: resolvedSurface.surfaceID,
                requestID: requestID
            ) else {
                throw BackendProtocolError.malformedMessage
            }
            guard sequence < UInt64.max else {
                throw BackendProtocolError.malformedMessage
            }
            nextInputSequence = sequence + 1
        } catch {
            await fail()
            throw error
        }
    }

    /// Revokes this connection's exact input delegation and closes the control socket.
    public func close() async {
        guard !finished else { return }
        finished = true
        await revokeInputDelegationIfNeeded()
        await client.close()
    }

    private func fail() async {
        guard !finished else { return }
        finished = true
        await revokeInputDelegationIfNeeded()
        await client.close()
    }

    private func revokeInputDelegationIfNeeded() async {
        guard let delegation = inputDelegation,
              let resolvedSurface else {
            inputDelegation = nil
            nextInputSequence = nil
            return
        }
        inputDelegation = nil
        nextInputSequence = nil
        try? await inputAuthority.revokeTerminalCompatibilityInput(
            surfaceID: resolvedSurface.surfaceID,
            delegateIdentity: registrationIdentity,
            delegation: delegation
        )
    }

    private func beginInputOperation() async {
        if !inputOperationActive {
            inputOperationActive = true
            return
        }
        await withCheckedContinuation { inputOperationWaiters.append($0) }
    }

    private func endInputOperation() {
        guard inputOperationActive else { return }
        if inputOperationWaiters.isEmpty {
            inputOperationActive = false
        } else {
            inputOperationWaiters.removeFirst().resume()
        }
    }

    private func resolve(
        _ surfaceID: SurfaceID,
        in topology: CanonicalTopology
    ) throws -> ResolvedSurface {
        for workspace in topology.workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    if let surface = pane.tabs.first(where: { $0.uuid == surfaceID }) {
                        guard surface.kind == "pty" else {
                            throw BackendTerminalSceneError.surfaceIsNotTerminal(surfaceID)
                        }
                        return ResolvedSurface(handle: surface.id, surfaceID: surfaceID)
                    }
                }
            }
        }
        throw BackendTerminalSceneError.surfaceNotFound(surfaceID)
    }

    private func validateIdentity(_ identify: BackendIdentifyResponse) throws {
        guard identify.session == expectation.session else {
            throw BackendCanonicalSessionError.unexpectedSession(
                expected: expectation.session,
                actual: identify.session
            )
        }
        if let authority = expectation.authority, identify.authority != authority {
            throw BackendCanonicalSessionError.unexpectedAuthority(
                expected: authority,
                actual: identify.authority
            )
        }
        if let processID = expectation.processID, identify.processID != processID {
            throw BackendCanonicalSessionError.unexpectedProcessID(
                expected: processID,
                actual: identify.processID
            )
        }
    }

    private func validateInputReceipt(
        _ receipt: BackendTerminalOperationReceipt,
        requestID: UUID,
        sequence: UInt64,
        leaseGeneration: UInt64,
        encodedBytes: UInt64
    ) throws {
        guard receipt.requestID == requestID,
              receipt.status == .applied,
              receipt.kind == .input,
              receipt.sequence == sequence,
              receipt.leaseGeneration == leaseGeneration,
              receipt.replayed == false,
              receipt.encodedBytes == encodedBytes,
              receipt.orderedInputSequence.map({ $0 > 0 }) == true,
              receipt.leaseRevoked == false else {
            throw BackendProtocolError.malformedMessage
        }
    }

    private func validateInputDelegation(
        _ delegation: BackendTerminalInputDelegation,
        surfaceID: SurfaceID
    ) throws {
        guard delegation.surfaceID == surfaceID,
              delegation.delegationID != Self.nilUUID,
              delegation.delegateClientUUID == registrationIdentity.clientUUID,
              delegation.delegateProcessInstanceUUID
                == registrationIdentity.processInstanceUUID,
              delegation.delegationGeneration > 0,
              delegation.ownerLeaseGeneration > 0,
              delegation.expiresAtMilliseconds > 0,
              delegation.nextSequence > 0,
              delegation.scopes == [.text] else {
            throw BackendProtocolError.malformedMessage
        }
    }

    private static let nilUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized.append(String(repeating: "=", count: (4 - normalized.count % 4) % 4))
        self.init(base64Encoded: normalized)
    }
}
