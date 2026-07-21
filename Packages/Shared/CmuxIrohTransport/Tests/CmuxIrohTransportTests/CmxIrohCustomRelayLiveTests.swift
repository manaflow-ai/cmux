import CMUXMobileCore
import CryptoKit
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
        case streamRoundTripTimedOut
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

    @Test(.enabled(if: CmxIrohCustomRelayLiveEnvironment.hasBrokerCredentials))
    func brokerBoundTokensCarryBidirectionalRoundTrip() async throws {
        let baseURL = try #require(URL(string: try CmxIrohCustomRelayLiveEnvironment.required(
            "CMUX_IROH_CUSTOM_RELAY_BROKER_URL"
        )))
        let accessToken = try CmxIrohCustomRelayLiveEnvironment.required(
            "CMUX_IROH_CUSTOM_RELAY_ACCESS_TOKEN"
        )
        let refreshToken = try CmxIrohCustomRelayLiveEnvironment.required(
            "CMUX_IROH_CUSTOM_RELAY_REFRESH_TOKEN"
        )
        let broker = try CmxIrohTrustBrokerClient(
            baseURL: baseURL,
            tokenSource: CmxIrohBrokerTokenSource(
                accessToken: { accessToken },
                refreshToken: { refreshToken }
            )
        )
        let runTag = "relay-live-\(UUID().uuidString.lowercased())"
        let firstSecretKey = try randomSecretKey()
        let secondSecretKey = try randomSecretKey()
        var bindingIDs: [String] = []
        var stage = "register first endpoint"

        do {
            print("Iroh live relay: \(stage)")
            let first = try await register(
                secretKey: firstSecretKey,
                tag: "\(runTag)-first",
                broker: broker
            )
            bindingIDs.append(first.bindingID)
            stage = "register second endpoint"
            print("Iroh live relay: \(stage)")
            let second = try await register(
                secretKey: secondSecretKey,
                tag: "\(runTag)-second",
                broker: broker
            )
            bindingIDs.append(second.bindingID)

            stage = "mint first endpoint-bound token"
            print("Iroh live relay: \(stage)")
            let firstToken = try await broker.issueRelayToken(
                bindingID: first.bindingID,
                endpointID: first.endpointID
            )
            stage = "mint second endpoint-bound token"
            print("Iroh live relay: \(stage)")
            let secondToken = try await broker.issueRelayToken(
                bindingID: second.bindingID,
                endpointID: second.endpointID
            )
            let firstCredentials = Dictionary(
                firstToken.credentials.map { ($0.relayURL, $0.token) },
                uniquingKeysWith: { _, latestToken in latestToken }
            )
            let commonRelayURL = try #require(
                secondToken.credentials.lazy
                    .map(\.relayURL)
                    .first(where: { firstCredentials[$0] != nil })
            )
            let firstAuthenticationToken = try #require(firstCredentials[commonRelayURL])
            let secondAuthenticationToken = try #require(
                secondToken.credentials.first(where: {
                    $0.relayURL == commonRelayURL
                })?.token
            )

            stage = "carry bidirectional relay-only stream"
            print("Iroh live relay: \(stage)")
            try await assertBidirectionalRoundTrip(
                relayURL: commonRelayURL,
                firstAuthenticationToken: firstAuthenticationToken,
                secondAuthenticationToken: secondAuthenticationToken,
                firstSecretKey: firstSecretKey,
                secondSecretKey: secondSecretKey
            )
        } catch {
            Issue.record("Iroh live relay failed while attempting to \(stage): \(error)")
            await revoke(bindingIDs: bindingIDs, broker: broker)
            throw error
        }
        await revoke(bindingIDs: bindingIDs, broker: broker)
    }

    private struct RegisteredEndpoint: Sendable {
        let bindingID: String
        let endpointID: CmxIrohPeerIdentity
    }

    private func register(
        secretKey: CmxIrohSecretKey,
        tag: String,
        broker: CmxIrohTrustBrokerClient
    ) async throws -> RegisteredEndpoint {
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: secretKey.bytes
        )
        let endpointID = privateKey.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }
            .joined()
        let identity = try CmxIrohIdentityMaterial(
            secretKey: secretKey,
            generation: 1
        )
        let signer = try CmxIrohRegistrationSigner(
            identity: identity,
            endpointID: endpointID
        )
        let payload = try CmxIrohRegistrationPayload(
            deviceID: UUID().uuidString.lowercased(),
            appInstanceID: UUID().uuidString.lowercased(),
            tag: tag,
            platform: .ios,
            endpointID: endpointID,
            identityGeneration: identity.generation,
            pairingEnabled: false,
            capabilities: ["rpc", "terminal.streams"],
            pathHints: []
        )
        let registration = try await broker.register(
            prepared: signer.prepare(payload: payload),
            signer: signer
        )
        #expect(registration.binding.endpointID.endpointID == endpointID)
        return RegisteredEndpoint(
            bindingID: registration.binding.bindingID,
            endpointID: registration.binding.endpointID
        )
    }

    private func randomSecretKey() throws -> CmxIrohSecretKey {
        try CmxIrohSecretKey(bytes: Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    private func revoke(
        bindingIDs: [String],
        broker: CmxIrohTrustBrokerClient
    ) async {
        for bindingID in bindingIDs.reversed() {
            do {
                try await broker.revoke(bindingID: bindingID)
            } catch {
                Issue.record("Failed to revoke disposable live-test binding")
            }
        }
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
        print("Iroh live relay: first endpoint bound")
        let second = try await factory.bind(
            configuration: CmxIrohEndpointConfiguration(
                secretKey: try secondSecretKey ?? CmxIrohSecretKey(
                    bytes: Data(repeating: 2, count: 32)
                ),
                alpns: [alpn],
                relayProfile: secondProfile
            )
        )
        print("Iroh live relay: second endpoint bound")

        do {
            let firstAddress = try await relayAddress(
                for: first,
                relayURL: relayURL
            )
            print("Iroh live relay: first relay address advertised")
            let secondAddress = try await relayAddress(
                for: second,
                relayURL: relayURL
            )
            print("Iroh live relay: second relay address advertised")
            #expect(firstAddress.pathHints.map(\.value) == [relayURL])
            #expect(secondAddress.pathHints.map(\.value) == [relayURL])

            let connections = try await connectPair(
                first: first,
                second: second,
                secondAddress: secondAddress,
                alpn: alpn
            )
            print("Iroh live relay: endpoint connection established")
            let outgoingConnection = connections.outgoing
            let incomingConnection = connections.incoming

            try await carryBoundedStreamRoundTrip(
                outgoingConnection: outgoingConnection,
                incomingConnection: incomingConnection
            )

            #expect(
                try await relayPath(
                    for: outgoingConnection,
                    relayURL: relayURL
                ) == .relay(url: relayURL)
            )
            print("Iroh live relay: outgoing path verified as relay")
            #expect(
                try await relayPath(
                    for: incomingConnection,
                    relayURL: relayURL
                ) == .relay(url: relayURL)
            )
            print("Iroh live relay: incoming path verified as relay")

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

    private func carryBoundedStreamRoundTrip(
        outgoingConnection: any CmxIrohConnection,
        incomingConnection: any CmxIrohConnection
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await outgoingConnection.setIncomingStreamLimits(
                    maximumBidirectionalStreamCount: 1,
                    maximumUnidirectionalStreamCount: 0
                )
                print("Iroh live relay: outgoing stream limits configured")
                try await incomingConnection.setIncomingStreamLimits(
                    maximumBidirectionalStreamCount: 1,
                    maximumUnidirectionalStreamCount: 0
                )
                print("Iroh live relay: incoming stream limits configured")

                async let acceptedStream = incomingConnection.acceptBidirectionalStream()
                print("Iroh live relay: waiting for incoming stream")
                let outgoingStream = try await outgoingConnection.openBidirectionalStream()
                print("Iroh live relay: outgoing stream created")
                let request = Data("custom-relay-request".utf8)
                try await outgoingStream.sendStream.send(request)
                try await outgoingStream.sendStream.finish()
                let incomingStream = try await acceptedStream
                print("Iroh live relay: bidirectional stream opened")
                #expect(try await self.receiveAll(from: incomingStream.receiveStream) == request)
                print("Iroh live relay: request received")

                let response = Data("custom-relay-response".utf8)
                try await incomingStream.sendStream.send(response)
                try await incomingStream.sendStream.finish()
                #expect(try await self.receiveAll(from: outgoingStream.receiveStream) == response)
                print("Iroh live relay: response received")
            }
            group.addTask {
                try await ContinuousClock().sleep(
                    for: .seconds(CmxIrohCustomRelayLiveEnvironment.timeout)
                )
                await outgoingConnection.close(errorCode: 1, reason: "live_test_timeout")
                await incomingConnection.close(errorCode: 1, reason: "live_test_timeout")
                throw LiveTestError.streamRoundTripTimedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
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
