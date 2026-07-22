import CMUXMobileCore
import Darwin
import Foundation
import IrohLib
import Testing
@testable import CmuxIrohTransport

@Suite(.serialized)
struct CmxIrohLibEndpointTests {
    @Test
    func verificationModeSelectsTheExpectedIrohRelayMode() throws {
        let cases: [(CmxIrohTransportVerificationMode, Bool)] = [
            (.automatic, false),
            (.relayOnly, false),
            (.directOnly, true),
        ]
        for (mode, expectsDisabledRelayMode) in cases {
            let options = CmxIrohLibEndpointFactory.endpointOptions(
                configuration: try CmxIrohEndpointConfiguration(
                    secretKey: CmxIrohSecretKey(bytes: Data(repeating: 7, count: 32)),
                    alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                    managedRelayURLs: [],
                    relays: []
                ),
                socketAddress: nil,
                relayMap: RelayMap.empty(),
                transportVerificationMode: mode
            )

            #expect(
                (options.relayMode?.description == "disabled")
                    == expectsDisabledRelayMode
            )
        }
    }

    @Test
    func relayOnlyVerificationModeDisablesPostAdmissionNATTraversal() {
        #expect(CmxIrohTransportVerificationMode.automatic.allowsNATTraversalAfterAdmission)
        #expect(!CmxIrohTransportVerificationMode.relayOnly.allowsNATTraversalAfterAdmission)
        #expect(CmxIrohTransportVerificationMode.directOnly.allowsNATTraversalAfterAdmission)
    }

    @Test
    func cmuxEndpointStartsWithNoStreamCreditOrPreAdmissionNatTraversal() throws {
        let options = CmxIrohLibEndpointFactory.endpointOptions(
            configuration: try CmxIrohEndpointConfiguration(
                secretKey: CmxIrohSecretKey(bytes: Data(repeating: 7, count: 32)),
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: [],
                relays: []
            ),
            socketAddress: nil,
            relayMap: RelayMap.empty()
        )

        #expect(options.portMappingEnabled == false)
        #expect(options.deferNatTraversalUntilAuthorized == true)
        #expect(options.initialMaxConcurrentBiStreams == 0)
        #expect(options.initialMaxConcurrentUniStreams == 0)
    }

    @Test
    func minimalPresetPreservesIdentityWithoutPublicN0Relays() async throws {
        let endpoint = try await makeEndpoint(managedRelayURLs: [])
        let expectedID =
            "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"

        #expect(await endpoint.identity().endpointID == expectedID)
        let address = await endpoint.address()
        #expect(address.identity.endpointID == expectedID)
        #expect(address.pathHints.allSatisfy { $0.kind != .relayURL })
        let localDirectAddresses = await endpoint.localDirectAddresses()
        #expect(localDirectAddresses.allSatisfy { !$0.hasPrefix("https://") })
        #expect(address.pathHints.allSatisfy { hint in
            hint.privacyScope == .publicInternet
                && (!localDirectAddresses.contains(hint.value)
                    || hint.publicDisclosure(at: Date()) != nil)
        })

        let events = await endpoint.healthEvents()
        let collected = Task { () -> [CmxIrohEndpointHealthEvent] in
            var values: [CmxIrohEndpointHealthEvent] = []
            for await event in events { values.append(event) }
            return values
        }
        await endpoint.close()
        let observed = await collected.value
        #expect(!observed.contains(.closedUnexpectedly))
    }

    @Test
    func monitoringDoesNotSynthesizeNetworkChangeEvents() async throws {
        let endpoint = try await makeEndpoint(managedRelayURLs: [])
        let events = await endpoint.healthEvents()
        let collected = Task { () -> Int in
            var networkChanges = 0
            for await event in events {
                if event == .networkChanged {
                    networkChanges += 1
                }
                if networkChanges == 32 {
                    break
                }
            }
            return networkChanges
        }

        for _ in 0 ..< 100 {
            await Task.yield()
        }
        await endpoint.close()

        #expect(await collected.value < 32)
    }

    @Test
    func directOnlyReplaysAddressObservedBeforeHealthSubscription() async throws {
        let (endpoint, observedAddress) = try await makeUnmonitoredEndpoint(
            transportVerificationMode: .directOnly
        )

        await endpoint.recordAddressSnapshot(observedAddress)

        let events = await endpoint.healthEvents()
        #expect(
            await firstHealthEvent(in: events, timeout: .seconds(1)) == .networkChanged
        )
        await endpoint.close()
    }

    @Test
    func onlineStateReplaysToLateHealthObservers() async throws {
        let endpoint = try await makeEndpoint(managedRelayURLs: [])
        let concrete = try #require(endpoint as? CmxIrohLibEndpoint)
        await concrete.recordHealthEvent(.online)

        let initialEvents = await endpoint.healthEvents()
        #expect(
            await firstHealthEvent(in: initialEvents, timeout: .seconds(2)) == .online
        )
        let lateEvents = await endpoint.healthEvents()
        #expect(
            await firstHealthEvent(in: lateEvents, timeout: .seconds(1)) == .online
        )

        await endpoint.close()
    }

    @Test
    func unmanagedRelayFailsAndManagedRelayFailoverBuildsSeparateAttempts() async throws {
        let first = "https://use1-1.relay.lawrence.cmux.iroh.link/"
        let second = "https://usw1-1.relay.lawrence.cmux.iroh.link/"
        let endpoint = try await makeEndpoint(managedRelayURLs: [first, second])
        let identity = await endpoint.identity()
        let now = Date()
        let unknown = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://relay.example.com/",
            source: .native,
            privacyScope: .publicInternet,
            observedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        await #expect(throws: CmxIrohLibError.unmanagedRelayURL(unknown.value)) {
            _ = try await endpoint.connect(
                to: CmxIrohEndpointAddress(identity: identity, pathHints: [unknown]),
                alpn: CmxIrohProtocolConfiguration.cmuxMobileV1.alpn
            )
        }

        let hints = try [first, second].map { value in
            try CmxIrohPathHint(
                kind: .relayURL,
                value: value,
                source: .native,
                privacyScope: .publicInternet,
                observedAt: now,
                expiresAt: now.addingTimeInterval(60)
            )
        }
        let concrete = try #require(endpoint as? CmxIrohLibEndpoint)
        let attempts = try await concrete.endpointAddresses(
            CmxIrohEndpointAddress(identity: identity, pathHints: hints)
        )
        #expect(attempts.map { $0.relayUrl() } == [first, second])
        await endpoint.close()
    }

    @Test
    func liveCustomProfileReplacesTheAllowlistWithoutChangingIdentity() async throws {
        let endpoint = try await makeEndpoint(managedRelayURLs: [])
        let concrete = try #require(endpoint as? CmxIrohLibEndpoint)
        let identity = await endpoint.identity()
        let customURL = "https://private.example.net:8443/"
        let custom = try CmxIrohCustomRelayProfile(
            relays: [CmxIrohCustomRelay(url: customURL)]
        )

        try await endpoint.replaceRelayProfile(
            CmxIrohEndpointRelayProfile(customProfile: custom)
        )

        let now = Date()
        let hint = try CmxIrohPathHint(
            kind: .relayURL,
            value: customURL,
            source: .native,
            privacyScope: .publicInternet,
            observedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let attempts = try await concrete.endpointAddresses(
            CmxIrohEndpointAddress(identity: identity, pathHints: [hint])
        )
        #expect(attempts.map { $0.relayUrl() } == [customURL])
        #expect(await endpoint.identity() == identity)

        try await endpoint.replaceRelayProfile(
            CmxIrohEndpointRelayProfile(managedRelayURLs: [], relays: [])
        )
        await #expect(throws: CmxIrohLibError.unmanagedRelayURL(customURL)) {
            _ = try await concrete.endpointAddresses(
                CmxIrohEndpointAddress(identity: identity, pathHints: [hint])
            )
        }
        await endpoint.close()
    }

    @Test
    func directOnlyIgnoresRelayPolicyReplacementAndRelayHints() async throws {
        let endpoint = try await makeEndpoint(
            managedRelayURLs: [],
            transportVerificationMode: .directOnly
        )
        let concrete = try #require(endpoint as? CmxIrohLibEndpoint)
        let identity = await endpoint.identity()
        let relayURL = "https://private.example.net:8443/"
        let custom = try CmxIrohCustomRelayProfile(
            relays: [CmxIrohCustomRelay(url: relayURL)]
        )

        try await endpoint.replaceRelayProfile(
            CmxIrohEndpointRelayProfile(customProfile: custom)
        )

        let now = Date()
        let relayHint = try CmxIrohPathHint(
            kind: .relayURL,
            value: relayURL,
            source: .native,
            privacyScope: .publicInternet,
            observedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let directHint = try CmxIrohPathHint(
            kind: .directAddress,
            value: "8.8.8.8:50906",
            source: .native,
            privacyScope: .publicInternet,
            observedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let attempts = try await concrete.endpointAddresses(
            CmxIrohEndpointAddress(
                identity: identity,
                pathHints: [relayHint, directHint]
            )
        )

        #expect(attempts.count == 1)
        #expect(attempts.first?.relayUrl() == nil)
        #expect(attempts.first?.directAddresses() == [directHint.value])
        #expect(await endpoint.address().pathHints.allSatisfy { $0.kind != .relayURL })
        await endpoint.close()
    }

    @Test
    func relayOnlyIgnoresDirectAddressHintsAndAdvertisement() async throws {
        let endpoint = try await makeEndpoint(
            managedRelayURLs: [],
            transportVerificationMode: .relayOnly
        )
        let concrete = try #require(endpoint as? CmxIrohLibEndpoint)
        let identity = await endpoint.identity()
        let directHint = try CmxIrohPathHint(
            kind: .directAddress,
            value: "8.8.4.4:50906",
            source: .native,
            privacyScope: .publicInternet,
            observedAt: Date(),
            expiresAt: Date().addingTimeInterval(60)
        )

        let attempts = try await concrete.endpointAddresses(
            CmxIrohEndpointAddress(identity: identity, pathHints: [directHint])
        )

        #expect(attempts.count == 1)
        #expect(attempts.first?.directAddresses().isEmpty == true)
        #expect(await endpoint.localDirectAddresses().isEmpty)
        #expect(await endpoint.address().pathHints.allSatisfy { $0.kind != .directAddress })
        await endpoint.close()
    }

    @Test
    func requiredBindPortFailsOnCollisionAndSucceedsAfterRelease() async throws {
        let reservation = try reserveUDPPort()
        let policy = try CmxIrohEndpointBindPolicy.required(
            CmxIrohBindAddress(ipAddress: "127.0.0.1", port: reservation.port)
        )

        await #expect(throws: (any Error).self) {
            _ = try await makeEndpoint(managedRelayURLs: [], bindPolicy: policy)
        }
        Darwin.close(reservation.descriptor)

        let endpoint = try await makeEndpoint(
            managedRelayURLs: [],
            bindPolicy: policy
        )
        await endpoint.close()
    }

    @Test
    func preferredBindPortFallsBackWithoutKillingTheEndpoint() async throws {
        let reservation = try reserveUDPPort()
        defer { Darwin.close(reservation.descriptor) }
        let policy = try CmxIrohEndpointBindPolicy.preferred(
            CmxIrohBindAddress(ipAddress: "127.0.0.1", port: reservation.port)
        )

        let endpoint = try await makeEndpoint(
            managedRelayURLs: [],
            bindPolicy: policy
        )

        #expect(await endpoint.isHealthy())
        await endpoint.close()
    }

    private func reserveUDPPort() throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw currentPOSIXError() }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bound == 0 else {
            let error = currentPOSIXError()
            Darwin.close(descriptor)
            throw error
        }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let readAddress = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &addressLength)
            }
        }
        guard readAddress == 0 else {
            let error = currentPOSIXError()
            Darwin.close(descriptor)
            throw error
        }
        return (descriptor, UInt16(bigEndian: address.sin_port))
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func firstHealthEvent(
        in events: AsyncStream<CmxIrohEndpointHealthEvent>,
        timeout: Duration
    ) async -> CmxIrohEndpointHealthEvent? {
        await withTaskGroup(of: CmxIrohEndpointHealthEvent?.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                do {
                    try await ContinuousClock().sleep(for: timeout)
                } catch {
                    return nil
                }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func makeEndpoint(
        managedRelayURLs: Set<String>,
        bindPolicy: CmxIrohEndpointBindPolicy = .ephemeral,
        transportVerificationMode: CmxIrohTransportVerificationMode = .automatic
    ) async throws -> any CmxIrohEndpoint {
        let configuration = try CmxIrohEndpointConfiguration(
            secretKey: CmxIrohSecretKey(bytes: Data((0 ..< 32).map(UInt8.init))),
            alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
            bindPolicy: bindPolicy,
            managedRelayURLs: managedRelayURLs,
            relays: []
        )
        return try await CmxIrohLibEndpointFactory(
            transportVerificationMode: transportVerificationMode
        ).bind(configuration: configuration)
    }

    private func makeUnmonitoredEndpoint(
        transportVerificationMode: CmxIrohTransportVerificationMode
    ) async throws -> (endpoint: CmxIrohLibEndpoint, observedAddress: EndpointAddr) {
        let configuration = try CmxIrohEndpointConfiguration(
            secretKey: CmxIrohSecretKey(bytes: Data((0 ..< 32).map(UInt8.init))),
            alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
            managedRelayURLs: [],
            relays: []
        )
        let driver = try await Endpoint.bind(
            options: CmxIrohLibEndpointFactory.endpointOptions(
                configuration: configuration,
                socketAddress: nil,
                relayMap: RelayMap.empty(),
                transportVerificationMode: transportVerificationMode
            )
        )
        let endpoint = CmxIrohLibEndpoint(
            driver: driver,
            identity: try CmxIrohLibIdentity.peerIdentity(driver.id()),
            configuration: configuration,
            transportVerificationMode: transportVerificationMode
        )
        return (endpoint, driver.addr())
    }
}
