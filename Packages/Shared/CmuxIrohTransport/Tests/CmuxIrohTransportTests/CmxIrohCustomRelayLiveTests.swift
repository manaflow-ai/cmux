import Foundation
import Testing
@testable import CmuxIrohTransport

/// Opt-in live checks for real custom relay address selection. CI skips this
/// suite unless `CMUX_IROH_CUSTOM_RELAY_LIVE=1` is explicitly present.
@Suite(
    .serialized,
    .enabled(if: CmxIrohCustomRelayLiveEnvironment.isEnabled)
)
struct CmxIrohCustomRelayLiveTests {
    private enum LiveTestError: Error {
        case connectionTimedOut
        case endpointClosed
        case relayAddressTimedOut
        case relayPathTimedOut
    }

    private struct ConnectionPair: Sendable {
        let outgoing: any CmxIrohConnection
        let incoming: any CmxIrohConnection
    }

    @Test(.enabled(if: CmxIrohCustomRelayLiveEnvironment.hasNoTokenRelay))
    func unauthenticatedRelayUsesExactConfiguredURL() async throws {
        let relayURL = try CmxIrohCustomRelayLiveEnvironment.required(
            "CMUX_IROH_CUSTOM_RELAY_NO_TOKEN_URL"
        )
        let profile = CmxIrohEndpointRelayProfile(
            customProfile: try CmxIrohCustomRelayProfile(
                relays: [CmxIrohCustomRelay(url: relayURL)]
            )
        )

        let result = await CmxIrohCustomRelayProbe().probe(
            profile: profile,
            timeout: CmxIrohCustomRelayLiveEnvironment.timeout
        )

        #expect(result == .reachable(relayURL: relayURL))
    }

    @Test(.enabled(if: CmxIrohCustomRelayLiveEnvironment.hasStaticTokenRelay))
    func staticTokenProfileAdvertisesExactConfiguredURL() async throws {
        // Relay advertisement proves exact FFI map selection, not provider
        // authentication. The product does not present this as a token test.
        let relayURL = try CmxIrohCustomRelayLiveEnvironment.required(
            "CMUX_IROH_CUSTOM_RELAY_STATIC_URL"
        )
        let token = try CmxIrohCustomRelayLiveEnvironment.required(
            "CMUX_IROH_CUSTOM_RELAY_STATIC_TOKEN"
        )
        let profile = CmxIrohEndpointRelayProfile(
            customProfile: try CmxIrohCustomRelayProfile(
                relays: [
                    CmxIrohCustomRelay(
                        url: relayURL,
                        authenticationToken: token
                    ),
                ]
            )
        )

        let result = await CmxIrohCustomRelayProbe().probe(
            profile: profile,
            timeout: CmxIrohCustomRelayLiveEnvironment.timeout
        )

        #expect(result == .reachable(relayURL: relayURL))
    }

    @Test(.enabled(if: CmxIrohCustomRelayLiveEnvironment.hasStaticTokenRelay))
    func staticTokenRelayCarriesBidirectionalRoundTrip() async throws {
        let relayURL = try CmxIrohCustomRelayLiveEnvironment.required(
            "CMUX_IROH_CUSTOM_RELAY_STATIC_URL"
        )
        let token = try CmxIrohCustomRelayLiveEnvironment.required(
            "CMUX_IROH_CUSTOM_RELAY_STATIC_TOKEN"
        )
        try await assertBidirectionalRoundTrip(
            relayURL: relayURL,
            firstAuthenticationToken: token,
            secondAuthenticationToken: token
        )
    }

    @Test(.enabled(if: CmxIrohCustomRelayLiveEnvironment.hasNoTokenRelay))
    func unauthenticatedRelayCarriesBidirectionalRoundTrip() async throws {
        let relayURL = try CmxIrohCustomRelayLiveEnvironment.required(
            "CMUX_IROH_CUSTOM_RELAY_NO_TOKEN_URL"
        )
        try await assertBidirectionalRoundTrip(
            relayURL: relayURL,
            firstAuthenticationToken: nil,
            secondAuthenticationToken: nil
        )
    }

    @Test(.enabled(if: CmxIrohCustomRelayLiveEnvironment.hasEndpointBoundTokenRelay))
    func endpointBoundTokensCarryBidirectionalRoundTrip() async throws {
        try await assertBidirectionalRoundTrip(
            relayURL: try CmxIrohCustomRelayLiveEnvironment.required(
                "CMUX_IROH_CUSTOM_RELAY_BOUND_URL"
            ),
            firstAuthenticationToken: try CmxIrohCustomRelayLiveEnvironment.required(
                "CMUX_IROH_CUSTOM_RELAY_FIRST_TOKEN"
            ),
            secondAuthenticationToken: try CmxIrohCustomRelayLiveEnvironment.required(
                "CMUX_IROH_CUSTOM_RELAY_SECOND_TOKEN"
            ),
            firstSecretKey: try CmxIrohCustomRelayLiveEnvironment.requiredSecretKey(
                "CMUX_IROH_CUSTOM_RELAY_FIRST_SECRET_KEY_HEX"
            ),
            secondSecretKey: try CmxIrohCustomRelayLiveEnvironment.requiredSecretKey(
                "CMUX_IROH_CUSTOM_RELAY_SECOND_SECRET_KEY_HEX"
            )
        )
    }

    private func assertBidirectionalRoundTrip(
        relayURL: String,
        firstAuthenticationToken: String?,
        secondAuthenticationToken: String?,
        firstSecretKey: CmxIrohSecretKey? = nil,
        secondSecretKey: CmxIrohSecretKey? = nil
    ) async throws {
        let firstProfile = CmxIrohEndpointRelayProfile(
            customProfile: try CmxIrohCustomRelayProfile(
                relays: [
                    CmxIrohCustomRelay(
                        url: relayURL,
                        authenticationToken: firstAuthenticationToken
                    ),
                ]
            )
        )
        let secondProfile = CmxIrohEndpointRelayProfile(
            customProfile: try CmxIrohCustomRelayProfile(
                relays: [
                    CmxIrohCustomRelay(
                        url: relayURL,
                        authenticationToken: secondAuthenticationToken
                    ),
                ]
            )
        )
        let factory = CmxIrohLibEndpointFactory(
            transportVerificationMode: .relayOnly
        )
        let alpn = Data("cmux/custom-relay-live/1".utf8)
        let first = try await factory.bind(
            configuration: CmxIrohEndpointConfiguration(
                secretKey: try firstSecretKey ?? CmxIrohSecretKey(
                    bytes: Data(repeating: 1, count: 32)
                ),
                alpns: [alpn],
                relayProfile: firstProfile
            )
        )
        let second = try await factory.bind(
            configuration: CmxIrohEndpointConfiguration(
                secretKey: try secondSecretKey ?? CmxIrohSecretKey(
                    bytes: Data(repeating: 2, count: 32)
                ),
                alpns: [alpn],
                relayProfile: secondProfile
            )
        )

        do {
            let firstAddress = try await relayAddress(
                for: first,
                relayURL: relayURL
            )
            let secondAddress = try await relayAddress(
                for: second,
                relayURL: relayURL
            )
            #expect(firstAddress.pathHints.map(\.value) == [relayURL])
            #expect(secondAddress.pathHints.map(\.value) == [relayURL])

            let connections = try await connectPair(
                first: first,
                second: second,
                secondAddress: secondAddress,
                alpn: alpn
            )
            let outgoingConnection = connections.outgoing
            let incomingConnection = connections.incoming

            try await outgoingConnection.setIncomingStreamLimits(
                maximumBidirectionalStreamCount: 1,
                maximumUnidirectionalStreamCount: 0
            )
            try await incomingConnection.setIncomingStreamLimits(
                maximumBidirectionalStreamCount: 1,
                maximumUnidirectionalStreamCount: 0
            )

            async let acceptedStream = incomingConnection.acceptBidirectionalStream()
            let outgoingStream = try await outgoingConnection.openBidirectionalStream()
            let incomingStream = try await acceptedStream
            let request = Data("custom-relay-request".utf8)
            try await outgoingStream.sendStream.send(request)
            try await outgoingStream.sendStream.finish()
            #expect(try await receiveAll(from: incomingStream.receiveStream) == request)

            let response = Data("custom-relay-response".utf8)
            try await incomingStream.sendStream.send(response)
            try await incomingStream.sendStream.finish()
            #expect(try await receiveAll(from: outgoingStream.receiveStream) == response)

            #expect(
                try await relayPath(
                    for: outgoingConnection,
                    relayURL: relayURL
                ) == .relay(url: relayURL)
            )
            #expect(
                try await relayPath(
                    for: incomingConnection,
                    relayURL: relayURL
                ) == .relay(url: relayURL)
            )

            await outgoingConnection.close(errorCode: 0, reason: "live_test_complete")
            await incomingConnection.close(errorCode: 0, reason: "live_test_complete")
        } catch {
            await first.close()
            await second.close()
            throw error
        }
        await first.close()
        await second.close()
    }

    private func connectPair(
        first: any CmxIrohEndpoint,
        second: any CmxIrohEndpoint,
        secondAddress: CmxIrohEndpointAddress,
        alpn: Data
    ) async throws -> ConnectionPair {
        try await withThrowingTaskGroup(of: ConnectionPair.self) { group in
            group.addTask {
                async let acceptedConnection = second.accept()
                let outgoingConnection = try await first.connect(
                    to: secondAddress,
                    alpn: alpn
                )
                let incomingConnection = try #require(await acceptedConnection)
                return ConnectionPair(
                    outgoing: outgoingConnection,
                    incoming: incomingConnection
                )
            }
            group.addTask {
                try await ContinuousClock().sleep(
                    for: .seconds(CmxIrohCustomRelayLiveEnvironment.timeout)
                )
                // The FFI connect/accept futures do not currently unwind from
                // Swift task cancellation alone. Closing both disposable live
                // endpoints makes this external-network gate deterministically bounded.
                await first.close()
                await second.close()
                throw LiveTestError.connectionTimedOut
            }
            defer { group.cancelAll() }
            guard let pair = try await group.next() else {
                throw LiveTestError.connectionTimedOut
            }
            return pair
        }
    }

    private func relayAddress(
        for endpoint: any CmxIrohEndpoint,
        relayURL: String
    ) async throws -> CmxIrohEndpointAddress {
        let deadline = Date().addingTimeInterval(CmxIrohCustomRelayLiveEnvironment.timeout)
        while Date() < deadline {
            let address = await endpoint.address()
            if address.pathHints.contains(where: {
                $0.kind == .relayURL && $0.value == relayURL
            }) {
                return address
            }
            if !(await endpoint.isHealthy()) {
                throw LiveTestError.endpointClosed
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LiveTestError.relayAddressTimedOut
    }

    private func relayPath(
        for connection: any CmxIrohConnection,
        relayURL: String
    ) async throws -> CmxIrohObservedConnectionPath {
        let connection = try #require(
            connection as? any CmxIrohConnectionPathInspecting
        )
        let deadline = Date().addingTimeInterval(CmxIrohCustomRelayLiveEnvironment.timeout)
        while Date() < deadline {
            let path = await connection.observedSelectedPath()
            if path == .relay(url: relayURL) {
                return path
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LiveTestError.relayPathTimedOut
    }

    private func receiveAll(
        from stream: any CmxIrohReceiveStream
    ) async throws -> Data {
        var result = Data()
        while let chunk = try await stream.receive(maximumByteCount: 4_096) {
            result.append(chunk)
        }
        return result
    }
}
