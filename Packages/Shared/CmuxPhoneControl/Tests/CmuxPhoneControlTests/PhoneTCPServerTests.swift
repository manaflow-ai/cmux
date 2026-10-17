#if canImport(Network)
import Foundation
import Network
import Testing

@testable import CmuxPhoneControl

@Suite("cmux.phone TCP transport")
struct PhoneTCPServerTests {
    @Test
    func localhostSocketRoundTripsARequest() async throws {
        let server = try PhoneTCPServer(port: 0, driver: MockPhoneDriver())
        let port = try await server.start()
        defer { server.stop() }

        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        defer { connection.cancel() }
        try await waitUntilReady(connection)

        let request = try PhoneWireCodec().encode(.request(id: "tcp-1", method: "device.list"))
        try await send(request, on: connection)
        var lineDecoder = PhoneLineDecoder()
        var response: PhoneEnvelope?
        for _ in 0..<4 where response == nil {
            let bytes = try await receive(on: connection)
            response = try lineDecoder.append(bytes).first
        }
        #expect(response?.type == .response)
        #expect(response?.id == "tcp-1")
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "com.cmux.phone-control.test"))
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func receive(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: PhoneProtocol.maxLineBytes) {
                data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: PhoneDriverError.transport("socket closed")) }
            }
        }
    }
}
#endif
