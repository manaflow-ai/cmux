public import CmuxTerminalBackend
internal import Darwin
internal import Foundation

private enum BackendServiceHandoffConnectionError: Error, Sendable {
    case alreadyConnected
    case notConnected
    case unexpectedPeerUser(expected: UInt32, actual: UInt32)
    case peerRunsInClientProcess(UInt32)
    case reportedProcessMismatch(kernel: UInt32, reported: UInt32)
    case unexpectedSession(expected: String, actual: String)
    case insufficientRole(BackendConnectionRole)
    case invalidPermit
}

/// Holds the authenticated Unix connection that owns one daemon drain permit.
internal actor BackendServiceProtocolHandoffConnection: BackendServiceHandoffConnecting {
    private static let policy = BackendHandshakePolicy(
        supportedRange: 9 ... 9,
        minimumReadWriteProtocol: 9,
        requiredCapabilities: ["service-handoff-v1"]
    )

    private let expectedSession: String
    private let expectedUserID: UInt32
    private let clientProcessID: UInt32
    private let registrationIdentity: BackendClientRegistrationIdentity
    private let transportFactory: @Sendable () -> any BackendPeerIdentityTransport
    private var transport: (any BackendPeerIdentityTransport)?
    private var client: BackendProtocolClient?
    private var identity: BackendIdentifyResponse?
    private var registration: BackendClientRegistration?
    private var trustedPair: BackendServiceInstalledPair?

    internal init(
        descriptor: BackendServiceDescriptor,
        runtimePaths: BackendServiceRuntimePaths,
        processInstanceUUID: UUID,
        expectedUserID: UInt32? = nil,
        clientProcessID: UInt32? = nil,
        transportFactory: (@Sendable () -> any BackendPeerIdentityTransport)? = nil
    ) {
        expectedSession = descriptor.sessionName
        self.expectedUserID = expectedUserID ?? UInt32(geteuid())
        self.clientProcessID = clientProcessID ?? UInt32(getpid())
        registrationIdentity = BackendClientRegistrationIdentity(
            clientUUID: UUID(),
            processInstanceUUID: processInstanceUUID
        )!
        self.transportFactory = transportFactory ?? {
            UnixBackendTransport(path: runtimePaths.socketURL.path)
        }
    }

    func connect(trustedPair: BackendServiceInstalledPair) async throws {
        guard client == nil else { throw BackendServiceHandoffConnectionError.alreadyConnected }
        let transport = transportFactory()
        let client = BackendProtocolClient(transport: transport)
        do {
            try await client.connect()
            let peer = try await transport.peerIdentity()
            guard peer.userID == expectedUserID else {
                throw BackendServiceHandoffConnectionError.unexpectedPeerUser(
                    expected: expectedUserID,
                    actual: peer.userID
                )
            }
            guard peer.processID != clientProcessID else {
                throw BackendServiceHandoffConnectionError.peerRunsInClientProcess(peer.processID)
            }
            _ = try SystemBackendPeerTrustVerifier(
                expectedExecutableURL: trustedPair.backendExecutableURL
            ).verify(peer)

            let identity = try await client.identify()
            guard identity.processID == peer.processID else {
                throw BackendServiceHandoffConnectionError.reportedProcessMismatch(
                    kernel: peer.processID,
                    reported: identity.processID
                )
            }
            guard identity.session == expectedSession else {
                throw BackendServiceHandoffConnectionError.unexpectedSession(
                    expected: expectedSession,
                    actual: identity.session
                )
            }
            guard case .readWrite = try Self.policy.validate(identity) else {
                throw BackendProtocolError.missingCapabilities(["service-handoff-v1"])
            }
            let registration = try await client.registerClient(
                supportedRange: 9 ... 9,
                identity: registrationIdentity,
                kind: .serviceCoordinator
            )
            guard registration.role == .serviceCoordinator,
                  registration.protocolVersion == 9,
                  registration.topologyMutationLease == nil
            else {
                throw BackendServiceHandoffConnectionError.insufficientRole(registration.role)
            }

            self.transport = transport
            self.client = client
            self.identity = identity
            self.registration = registration
            self.trustedPair = trustedPair
        } catch {
            await client.close()
            throw error
        }
    }

    func prepare(targetBuildID: String) async throws -> BackendServiceHandoffPreparation {
        guard let client, let identity, let registration, let trustedPair else {
            throw BackendServiceHandoffConnectionError.notConnected
        }
        let preparation = try await client.prepareServiceHandoff(targetBuildID: targetBuildID)
        guard case .prepared(let permit) = preparation else { return preparation }
        guard permit.ownerConnectionID == registration.connectionID,
              permit.authority == identity.authority,
              permit.session == expectedSession,
              permit.sourceBuildID == trustedPair.buildID,
              permit.targetBuildID == targetBuildID,
              permit.durableStorage.state != .degraded,
              !permit.durableStorage.unresolvedMutation,
              permit.durableStorage.unresolvedLaunchAttempts == 0
        else {
            throw BackendServiceHandoffConnectionError.invalidPermit
        }
        return preparation
    }

    func revalidate(_ permit: BackendServiceHandoffPermit) async throws {
        guard let client, let identity, let registration, let trustedPair,
              registration.connectionID == permit.ownerConnectionID
        else {
            throw BackendServiceHandoffConnectionError.notConnected
        }
        let current = try await client.identify()
        guard current.authority == identity.authority,
              current.processID == identity.processID,
              current.session == expectedSession,
              permit.authority == current.authority,
              permit.session == current.session,
              permit.sourceBuildID == trustedPair.buildID
        else {
            throw BackendServiceHandoffConnectionError.invalidPermit
        }
        guard case .readWrite = try Self.policy.validate(current) else {
            throw BackendProtocolError.missingCapabilities(["service-handoff-v1"])
        }
    }

    func cancel(_ permit: BackendServiceHandoffPermit) async throws {
        guard let client, registration?.connectionID == permit.ownerConnectionID else {
            throw BackendServiceHandoffConnectionError.notConnected
        }
        try await client.cancelServiceHandoff(permit)
    }

    func close() async {
        let client = client
        self.client = nil
        transport = nil
        identity = nil
        registration = nil
        trustedPair = nil
        await client?.close()
    }
}
