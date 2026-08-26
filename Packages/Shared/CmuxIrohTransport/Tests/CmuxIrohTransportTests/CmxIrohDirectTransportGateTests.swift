import CMUXMobileCore
import Foundation
import IrohLib
import Testing
@testable import CmuxIrohTransport

/// Deterministic relay-disabled transport proof used by the iOS Simulator
/// release gate. Both peers are real Iroh endpoints. No cmux TCP transport is
/// constructed, so a raw loopback connection cannot satisfy this suite.
@Suite(.serialized)
struct CmxIrohDirectTransportGateTests {
    private enum GateError: Error {
        case connectionTimedOut
        case selectedPathTimedOut
    }

    private struct ConnectionPair: Sendable {
        let outgoing: CmxIrohLibConnection
        let incoming: CmxIrohLibConnection
    }

    @Test
    func relayDisabledEndpointsCarryAuthenticatedBidirectionalRoundTrip() async throws {
        let alpn = Data("cmux/direct-transport-gate/1".utf8)
        let first = try await endpoint(secretByte: 41, alpn: alpn)
        let second = try await endpoint(secretByte: 42, alpn: alpn)

        do {
            let secondAddress = second.addr()
            #expect(secondAddress.relayUrl() == nil)
            #expect(!secondAddress.directAddresses().isEmpty)

            let pair = try await connectPair(
                first: first,
                second: second,
                secondAddress: secondAddress,
                alpn: alpn
            )
            let firstIdentity = try CmxIrohLibIdentity.peerIdentity(first.id())
            let secondIdentity = try CmxIrohLibIdentity.peerIdentity(second.id())
            #expect(await pair.outgoing.remoteIdentity() == secondIdentity)
            #expect(await pair.incoming.remoteIdentity() == firstIdentity)

            try await pair.outgoing.setIncomingStreamLimits(
                maximumBidirectionalStreamCount: 1,
                maximumUnidirectionalStreamCount: 0
            )
            try await pair.incoming.setIncomingStreamLimits(
                maximumBidirectionalStreamCount: 1,
                maximumUnidirectionalStreamCount: 0
            )
            try await pair.outgoing.authorizeNatTraversal()
            try await pair.incoming.authorizeNatTraversal()

            async let acceptedStream = pair.incoming.acceptBidirectionalStream()
            let outgoingStream = try await pair.outgoing.openBidirectionalStream()
            let request = Data("direct-gate-request".utf8)
            try await outgoingStream.sendStream.send(request)
            try await outgoingStream.sendStream.finish()
            let incomingStream = try await acceptedStream
            #expect(try await receiveAll(from: incomingStream.receiveStream) == request)

            let response = Data("direct-gate-response".utf8)
            try await incomingStream.sendStream.send(response)
            try await incomingStream.sendStream.finish()
            #expect(try await receiveAll(from: outgoingStream.receiveStream) == response)

            #expect(try await directPath(for: pair.outgoing))
            #expect(try await directPath(for: pair.incoming))

            await pair.outgoing.close(errorCode: 0, reason: "direct_gate_complete")
            await pair.incoming.close(errorCode: 0, reason: "direct_gate_complete")
        } catch {
            try? await first.close()
            try? await second.close()
            throw error
        }
        try await first.close()
        try await second.close()
    }

    private func endpoint(
        secretByte: UInt8,
        alpn: Data
    ) async throws -> Endpoint {
        let configuration = try CmxIrohEndpointConfiguration(
            secretKey: CmxIrohSecretKey(bytes: Data(repeating: secretByte, count: 32)),
            alpns: [alpn],
            managedRelayURLs: [],
            relays: []
        )
        let options = CmxIrohLibEndpointFactory.endpointOptions(
            configuration: configuration,
            socketAddress: "127.0.0.1:0",
            relayMap: RelayMap.empty(),
            transportVerificationMode: .directOnly
        )
        #expect(options.relayMode?.description == "disabled")
        #expect(options.bindAddr == "127.0.0.1:0")
        #expect(options.initialMaxConcurrentBiStreams == 0)
        #expect(options.initialMaxConcurrentUniStreams == 0)
        return try await Endpoint.bind(options: options)
    }

    private func connectPair(
        first: Endpoint,
        second: Endpoint,
        secondAddress: EndpointAddr,
        alpn: Data
    ) async throws -> ConnectionPair {
        try await withThrowingTaskGroup(of: ConnectionPair.self) { group in
            group.addTask {
                async let incoming = self.acceptConnection(from: second, alpn: alpn)
                let outgoing = try CmxIrohLibConnection(
                    driver: try await first.connect(addr: secondAddress, alpn: alpn)
                )
                return ConnectionPair(outgoing: outgoing, incoming: try await incoming)
            }
            group.addTask {
                try await ContinuousClock().sleep(for: .seconds(20))
                try? await first.close()
                try? await second.close()
                throw GateError.connectionTimedOut
            }
            defer { group.cancelAll() }
            return try #require(await group.next())
        }
    }

    private func acceptConnection(
        from endpoint: Endpoint,
        alpn: Data
    ) async throws -> CmxIrohLibConnection {
        let incoming = try #require(await endpoint.acceptNext())
        let accepting = try await incoming.accept()
        #expect(try await accepting.alpn() == alpn)
        return try CmxIrohLibConnection(driver: try await accepting.connect())
    }

    private func directPath(
        for connection: CmxIrohLibConnection
    ) async throws -> Bool {
        let deadline = ContinuousClock().now.advanced(by: .seconds(10))
        while ContinuousClock().now < deadline {
            switch await connection.observedSelectedPath() {
            case .direct, .privateNetwork:
                return true
            case .relay:
                return false
            case .unavailable:
                try await ContinuousClock().sleep(for: .milliseconds(50))
            }
        }
        throw GateError.selectedPathTimedOut
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
