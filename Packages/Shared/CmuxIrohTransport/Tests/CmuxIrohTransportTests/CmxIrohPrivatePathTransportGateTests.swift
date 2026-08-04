import CMUXMobileCore
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CmuxIrohTransport

/// Release-gate coverage for the provider-neutral custom-private-path contract.
///
/// The successful case traverses a real non-loopback host interface. It proves
/// the app contract without claiming that CI owns an external VPN tunnel.
@Suite(.serialized)
struct CmxIrohPrivatePathTransportGateTests {
    private struct BoundServer {
        let endpoint: any CmxIrohEndpoint
        let port: UInt16
    }

    private enum GateError: Error {
        case connectionTimedOut
        case noPrivateIPv4Interface
        case portAllocationFailed
    }

    @Test
    func brokerAuthorizedCustomAddressCarriesPrivateRPC() async throws {
        let now = Date()
        let fixture = try RegistryFixture(
            now: now,
            initiatorSecretKey: Data(repeating: 1, count: 32),
            acceptorSecretKey: Data(repeating: 10, count: 32)
        )
        let ipAddress = try privateIPv4Address()
        let profile = try privateNetworkProfile(id: "release-gate")
        let customPath = try CmxIrohCustomPrivatePathBootstrap(
            address: CmxIrohCustomPrivateAddress(ipAddress),
            networkProfile: profile
        )
        let clientSupervisor = try await realClientSupervisor(fixture: fixture)
        let server = try await realServerEndpoint(
            fixture: fixture,
            ipAddress: ipAddress
        )
        let serverEndpoint = server.endpoint
        let port = server.port

        do {
            let clientEndpoint = try await clientSupervisor.activeEndpoint()
            #expect(await clientEndpoint.identity() == fixture.initiator.endpointID)
            #expect(await serverEndpoint.identity() == fixture.acceptor.endpointID)

            let discovery = try fixture.discovery(
                targetHints: [],
                targetDirectPorts: ["ipv4": Int(port)],
                targetLastSeenAt: now
            )
            let broker = TestIrohRegistryBroker(
                discovery: discovery,
                pairGrantResponses: [try fixture.pairGrantResponse(
                    issuedAt: fixture.nowSeconds,
                    expiresAt: fixture.nowSeconds + 300
                )]
            )
            let provider = CmxIrohRegistryContextProvider(
                supervisor: clientSupervisor,
                broker: broker,
                localBindingExpectation: try fixture.localExpectation(),
                managedRelayURLs: [fixture.relayURL],
                networkPathSnapshot: {
                    CmxIrohNetworkPathSnapshot(
                        generation: 1,
                        activeNetworkProfiles: [profile]
                    )
                },
                customPrivateFallback: { deviceID in
                    guard CmxIrohDeviceID(deviceID)
                        == CmxIrohDeviceID(fixture.acceptor.deviceID) else { return [] }
                    return [customPath]
                },
                now: { now }
            )
            let context = try await provider.context(for: fixture.request(hints: []))
            #expect(context.dialPlan.publicPaths.isEmpty)
            #expect(context.dialPlan.privateFallbackPaths.map(\.value) == [
                "\(ipAddress):\(port)",
            ])
            #expect(context.dialPlan.privateFallbackPaths.allSatisfy {
                $0.source == .customVPN
                    && $0.privacyScope == .privateNetwork
                    && $0.networkProfile == profile
            })
            #expect(context.credential.kind == .pairGrant)

            let authorizer = admissionController(
                fixture: fixture,
                broker: broker,
                discovery: discovery,
                now: now
            )
            let clientSession = try CmxIrohClientSession(
                endpoint: clientEndpoint,
                targetIdentity: fixture.acceptor.endpointID,
                dialPlan: context.dialPlan,
                credential: context.credential,
                privateFallbackAuthorization: context.privateFallbackAuthorization,
                privateFallbackValidator: provider
            )
            let serverSession = try await connect(
                clientSession: clientSession,
                serverEndpoint: serverEndpoint,
                authorizer: authorizer
            )

            let admittedPeer = try await serverSession.admittedPeerContext()
            #expect(admittedPeer.endpointID == fixture.initiator.endpointID)
            #expect(try await selectedPrivatePath(clientSession))

            let request = Data(
                #"{"jsonrpc":"2.0","id":1,"method":"cmux.privatePath.probe"}"#.utf8
            )
            try await clientSession.sendControl(request)
            #expect(try await serverSession.receiveControl(maximumByteCount: 4_096) == request)

            let response = Data(
                #"{"jsonrpc":"2.0","id":1,"result":{"path":"private_network"}}"#.utf8
            )
            try await serverSession.sendControl(response)
            #expect(try await clientSession.receiveControl(maximumByteCount: 4_096) == response)

            await clientSession.close()
            await serverSession.close()
        } catch {
            await clientSupervisor.deactivate()
            await serverEndpoint.close()
            throw error
        }
        await clientSupervisor.deactivate()
        await serverEndpoint.close()
    }

    @Test
    func wrongEndpointIdentityCannotUseTheLivePrivateCoordinate() async throws {
        let now = Date()
        let fixture = try RegistryFixture(
            now: now,
            initiatorSecretKey: Data(repeating: 2, count: 32),
            acceptorSecretKey: Data(repeating: 11, count: 32)
        )
        let ipAddress = try privateIPv4Address()
        let clientSupervisor = try await realClientSupervisor(fixture: fixture)
        let server = try await realServerEndpoint(
            fixture: fixture,
            ipAddress: ipAddress
        )
        let serverEndpoint = server.endpoint
        let port = server.port
        let clientEndpoint = try await clientSupervisor.activeEndpoint()
        let hint = try privateHint(
            ipAddress: ipAddress,
            port: port,
            profile: privateNetworkProfile(id: "wrong-identity"),
            now: now
        )
        let wrongIdentity = try peerIdentity(secretByte: 8)

        #expect(wrongIdentity != fixture.acceptor.endpointID)
        let outcome = await connectionAttemptOutcome(
            endpoint: clientEndpoint,
            address: CmxIrohEndpointAddress(
                identity: wrongIdentity,
                pathHints: [hint]
            )
        )
        #expect(outcome == .observationElapsed || outcome == .remoteIdentityMismatch)

        await clientSupervisor.deactivate()
        await serverEndpoint.close()
    }

    @Test
    func brokerWrongPortCannotReachTheLivePrivateEndpoint() async throws {
        let now = Date()
        let fixture = try RegistryFixture(
            now: now,
            initiatorSecretKey: Data(repeating: 3, count: 32),
            acceptorSecretKey: Data(repeating: 12, count: 32)
        )
        let ipAddress = try privateIPv4Address()
        let server = try await realServerEndpoint(
            fixture: fixture,
            ipAddress: ipAddress
        )
        let serverEndpoint = server.endpoint
        let serverPort = server.port
        let wrongPort = try differentAvailableUDPPort(
            ipAddress: ipAddress,
            excluding: serverPort
        )
        let profile = try privateNetworkProfile(id: "wrong-port")
        let customPath = try CmxIrohCustomPrivatePathBootstrap(
            address: CmxIrohCustomPrivateAddress(ipAddress),
            networkProfile: profile
        )
        let clientSupervisor = try await realClientSupervisor(fixture: fixture)

        do {
            let discovery = try fixture.discovery(
                targetHints: [],
                targetDirectPorts: ["ipv4": Int(wrongPort)],
                targetLastSeenAt: now
            )
            let broker = TestIrohRegistryBroker(
                discovery: discovery,
                pairGrantResponses: [try fixture.pairGrantResponse(
                    issuedAt: fixture.nowSeconds,
                    expiresAt: fixture.nowSeconds + 300
                )]
            )
            let provider = CmxIrohRegistryContextProvider(
                supervisor: clientSupervisor,
                broker: broker,
                localBindingExpectation: try fixture.localExpectation(),
                managedRelayURLs: [fixture.relayURL],
                networkPathSnapshot: {
                    CmxIrohNetworkPathSnapshot(
                        generation: 1,
                        activeNetworkProfiles: [profile]
                    )
                },
                customPrivateFallback: { _ in [customPath] },
                now: { now }
            )
            let context = try await provider.context(for: fixture.request(hints: []))
            let clientEndpoint = try await clientSupervisor.activeEndpoint()

            #expect(context.dialPlan.privateFallbackPaths.map(\.value) == [
                "\(ipAddress):\(wrongPort)",
            ])
            let outcome = await connectionAttemptOutcome(
                endpoint: clientEndpoint,
                address: CmxIrohEndpointAddress(
                    identity: fixture.acceptor.endpointID,
                    pathHints: context.dialPlan.privateFallbackPaths
                )
            )
            #expect(outcome == .observationElapsed || outcome == .dialFailed)
        } catch {
            await clientSupervisor.deactivate()
            await serverEndpoint.close()
            throw error
        }

        await clientSupervisor.deactivate()
        await serverEndpoint.close()
    }

    @Test
    func inactiveCustomRouteFailsBeforeDial() async throws {
        let now = Date()
        let fixture = try RegistryFixture(now: now)
        let ipAddress = try privateIPv4Address()
        let port = try availableUDPPort(ipAddress: ipAddress)
        let profile = try privateNetworkProfile(id: "inactive-route")
        let customPath = try CmxIrohCustomPrivatePathBootstrap(
            address: CmxIrohCustomPrivateAddress(ipAddress),
            networkProfile: profile
        )
        let clientSupervisor = try await realClientSupervisor(fixture: fixture)
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(
                targetHints: [],
                targetDirectPorts: ["ipv4": Int(port)],
                targetLastSeenAt: now
            ),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 300
            )]
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: clientSupervisor,
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            networkPathSnapshot: {
                CmxIrohNetworkPathSnapshot(
                    generation: 2,
                    activeNetworkProfiles: []
                )
            },
            customPrivateFallback: { _ in [customPath] },
            now: { now }
        )

        do {
            let context = try await provider.context(for: fixture.request(hints: []))
            #expect(context.dialPlan.publicPaths.isEmpty)
            #expect(context.dialPlan.privateFallbackPaths.isEmpty)
            #expect(context.privateFallbackAuthorization == nil)
            let endpoint = try await clientSupervisor.activeEndpoint()
            let session = try CmxIrohClientSession(
                endpoint: endpoint,
                targetIdentity: fixture.acceptor.endpointID,
                dialPlan: context.dialPlan,
                credential: context.credential,
                privateFallbackAuthorization: context.privateFallbackAuthorization,
                privateFallbackValidator: provider
            )
            await #expect(throws: CmxIrohRegistryContextError.dialPlanUnavailable) {
                try await session.connect()
            }
            await session.close()
        } catch {
            await clientSupervisor.deactivate()
            throw error
        }
        await clientSupervisor.deactivate()
    }

    private func realClientSupervisor(
        fixture: RegistryFixture
    ) async throws -> CmxIrohEndpointSupervisor {
        let configuration = try CmxIrohEndpointConfiguration(
            secretKey: CmxIrohSecretKey(bytes: fixture.privateKey.rawRepresentation),
            alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
            managedRelayURLs: [fixture.relayURL],
            relays: []
        )
        let supervisor = CmxIrohEndpointSupervisor(
            factory: CmxIrohLibEndpointFactory(transportVerificationMode: .directOnly),
            configuration: configuration
        )
        _ = try await supervisor.activate()
        return supervisor
    }

    private func realServerEndpoint(
        fixture: RegistryFixture,
        ipAddress: String
    ) async throws -> BoundServer {
        var lastError: (any Error)?
        for _ in 0 ..< 8 {
            let port = try availableUDPPort(ipAddress: ipAddress)
            do {
                let endpoint = try await realServerEndpoint(
                    fixture: fixture,
                    ipAddress: ipAddress,
                    port: port
                )
                return BoundServer(endpoint: endpoint, port: port)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? GateError.portAllocationFailed
    }

    private func realServerEndpoint(
        fixture: RegistryFixture,
        ipAddress: String,
        port: UInt16
    ) async throws -> any CmxIrohEndpoint {
        let configuration = try CmxIrohEndpointConfiguration(
            secretKey: CmxIrohSecretKey(bytes: fixture.acceptorSecretKey),
            alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
            bindPolicy: .required(CmxIrohBindAddress(ipAddress: ipAddress, port: port)),
            managedRelayURLs: [fixture.relayURL],
            relays: []
        )
        return try await CmxIrohLibEndpointFactory(
            transportVerificationMode: .directOnly
        ).bind(configuration: configuration)
    }

    private func admissionController(
        fixture: RegistryFixture,
        broker: TestIrohRegistryBroker,
        discovery: CmxIrohDiscoveryResponse,
        now: Date
    ) -> CmxIrohAdmissionController {
        let onlineRegistry = CmxIrohOnlineAdmissionRegistry(
            broker: broker,
            keys: discovery.grantVerificationKeys,
            acceptor: fixture.acceptor,
            managedRelayURLs: [fixture.relayURL],
            clock: FixedOnlineAdmissionClock(now: now)
        )
        return CmxIrohAdmissionController(
            acceptor: fixture.acceptor,
            pairingEnabled: true,
            offlineSessions: CmxIrohOfflinePairingSessions(pairingEnabled: true),
            onlineRegistry: onlineRegistry,
            now: { now }
        )
    }

    private func connect(
        clientSession: CmxIrohClientSession,
        serverEndpoint: any CmxIrohEndpoint,
        authorizer: CmxIrohAdmissionController
    ) async throws -> CmxIrohServerSession {
        try await withThrowingTaskGroup(of: CmxIrohServerSession.self) { group in
            group.addTask {
                async let serverSession = self.acceptAndAdmit(
                    endpoint: serverEndpoint,
                    authorizer: authorizer
                )
                try await clientSession.connect()
                return try await serverSession
            }
            group.addTask {
                // This is a bounded release-gate deadline, not state polling.
                try await ContinuousClock().sleep(for: .seconds(20))
                await clientSession.close()
                await serverEndpoint.close()
                throw GateError.connectionTimedOut
            }
            defer { group.cancelAll() }
            let session: CmxIrohServerSession? = try await group.next()
            guard let session else { throw GateError.connectionTimedOut }
            return session
        }
    }

    private func acceptAndAdmit(
        endpoint: any CmxIrohEndpoint,
        authorizer: CmxIrohAdmissionController
    ) async throws -> CmxIrohServerSession {
        let connection = try #require(try await endpoint.accept())
        let session = try CmxIrohServerSession(
            connection: connection,
            authorizer: authorizer
        )
        _ = try await session.admit()
        return session
    }

    private func selectedPrivatePath(
        _ session: CmxIrohClientSession
    ) async throws -> Bool {
        let paths = await session.observedSelectedPathChanges()
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await path in paths {
                    switch path {
                    case .privateNetwork: return true
                    case .direct, .relay: return false
                    case .unavailable: continue
                    }
                }
                return false
            }
            group.addTask {
                // This is a bounded release-gate deadline, not state polling.
                try await ContinuousClock().sleep(for: .seconds(10))
                throw GateError.connectionTimedOut
            }
            defer { group.cancelAll() }
            let selectedPathIsPrivate: Bool? = try await group.next()
            guard let selectedPathIsPrivate else { throw GateError.connectionTimedOut }
            return selectedPathIsPrivate
        }
    }

    private func connectionAttemptOutcome(
        endpoint: any CmxIrohEndpoint,
        address: CmxIrohEndpointAddress
    ) async -> ConnectionAttemptOutcome {
        await withTaskGroup(of: ConnectionAttemptOutcome.self) { group in
            group.addTask {
                do {
                    let connection = try await endpoint.connect(
                        to: address,
                        alpn: CmxIrohProtocolConfiguration.cmuxMobileV1.alpn
                    )
                    await connection.close(errorCode: 1, reason: "gate_unexpected_connection")
                    return .connected
                } catch CmxIrohLibError.remoteIdentityMismatch {
                    return .remoteIdentityMismatch
                } catch {
                    return .dialFailed
                }
            }
            group.addTask {
                // Iroh rejects an unknown cryptographic EndpointID before a
                // connection exists, so a wrong live coordinate can remain pending.
                // The same release-gate suite proves an authorized private
                // coordinate carries bidirectional RPC, so this is not the only
                // evidence used to assess network health.
                try? await ContinuousClock().sleep(for: .seconds(5))
                return .observationElapsed
            }
            let outcome = await group.next() ?? .observationElapsed
            group.cancelAll()
            if outcome == .observationElapsed {
                await endpoint.close()
            }
            return outcome
        }
    }

    private enum ConnectionAttemptOutcome: Equatable, Sendable {
        case connected
        case remoteIdentityMismatch
        case dialFailed
        case observationElapsed
    }

    private func privateIPv4Address() throws -> String {
        let addresses = try CmxIrohSystemLANInterfaceSnapshotProvider().interfaceAddresses()
        guard let address = addresses.first(where: {
            $0.family == .ipv4
                && CmxIrohIPAddressScope(socketAddress: "\($0.ipAddress):1").isPrivate
                && (try? CmxIrohCustomPrivateAddress($0.ipAddress)) != nil
        }) else {
            throw GateError.noPrivateIPv4Interface
        }
        return address.ipAddress
    }

    private func availableUDPPort(ipAddress: String) throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard ipAddress.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw GateError.noPrivateIPv4Interface
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw currentPOSIXError() }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let readAddress = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &addressLength)
            }
        }
        guard readAddress == 0 else { throw currentPOSIXError() }
        return UInt16(bigEndian: address.sin_port)
    }

    private func differentAvailableUDPPort(
        ipAddress: String,
        excluding excluded: UInt16
    ) throws -> UInt16 {
        for _ in 0 ..< 8 {
            let candidate = try availableUDPPort(ipAddress: ipAddress)
            if candidate != excluded { return candidate }
        }
        throw GateError.portAllocationFailed
    }

    private func privateNetworkProfile(id: String) throws -> CmxIrohNetworkProfileKey {
        try CmxIrohNetworkProfileKey(
            source: .customVPN,
            profileID: opaqueProfileID(id)
        )
    }

    private func privateHint(
        ipAddress: String,
        port: UInt16,
        profile: CmxIrohNetworkProfileKey,
        now: Date
    ) throws -> CmxIrohPathHint {
        try CmxIrohPathHint(
            kind: .directAddress,
            value: "\(ipAddress):\(port)",
            source: .customVPN,
            privacyScope: .privateNetwork,
            observedAt: now,
            expiresAt: now.addingTimeInterval(60),
            networkProfile: profile
        )
    }

    private func peerIdentity(secretByte: UInt8) throws -> CmxIrohPeerIdentity {
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: secretByte, count: 32)
        )
        let endpointID = key.publicKey.rawRepresentation.map {
            String(format: "%02x", $0)
        }.joined()
        return try CmxIrohPeerIdentity(endpointID: endpointID)
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
