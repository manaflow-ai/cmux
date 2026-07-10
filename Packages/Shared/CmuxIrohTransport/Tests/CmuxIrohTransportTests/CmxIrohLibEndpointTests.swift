import CMUXMobileCore
import Darwin
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite(.serialized)
struct CmxIrohLibEndpointTests {
    @Test
    func minimalPresetPreservesIdentityWithoutPublicN0Relays() async throws {
        let endpoint = try await makeEndpoint(managedRelayURLs: [])
        let expectedID =
            "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"

        #expect(await endpoint.identity().endpointID == expectedID)
        let address = await endpoint.address()
        #expect(address.identity.endpointID == expectedID)
        #expect(address.pathHints.allSatisfy { $0.kind != .relayURL })

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

    private func makeEndpoint(
        managedRelayURLs: Set<String>,
        bindPolicy: CmxIrohEndpointBindPolicy = .ephemeral
    ) async throws -> any CmxIrohEndpoint {
        let configuration = try CmxIrohEndpointConfiguration(
            secretKey: CmxIrohSecretKey(bytes: Data((0 ..< 32).map(UInt8.init))),
            alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
            bindPolicy: bindPolicy,
            managedRelayURLs: managedRelayURLs,
            relays: []
        )
        return try await CmxIrohLibEndpointFactory().bind(configuration: configuration)
    }
}
