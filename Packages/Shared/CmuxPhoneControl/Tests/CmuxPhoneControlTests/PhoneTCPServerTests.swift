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

    @Test
    func sessionsAreIsolatedPerConnection() async throws {
        let server = try PhoneTCPServer(port: 0, driver: MockPhoneDriver())
        let port = try await server.start()
        defer { server.stop() }

        let first = try await connect(to: port)
        let second = try await connect(to: port)
        defer {
            first.cancel()
            second.cancel()
        }

        let firstResponse = try await roundTrip(
            .request(id: "first-open", method: "session.open"),
            on: first
        )
        #expect(firstResponse.type == .response)
        let firstSessionID = try #require(firstResponse.sessionID)
        let firstClose = try await roundTrip(
            .request(id: "first-close", method: "session.close", sessionID: firstSessionID),
            on: first
        )
        #expect(firstClose.type == .response)

        let secondResponse = try await roundTrip(
            .request(id: "second-open", method: "session.open"),
            on: second
        )
        #expect(secondResponse.type == .response)
        #expect(firstResponse.sessionID != secondResponse.sessionID)
    }

    @Test
    func sessionLeaseIsExclusiveAcrossConnections() async throws {
        let server = try PhoneTCPServer(port: 0, driver: MockPhoneDriver())
        let port = try await server.start()
        defer { server.stop() }

        let first = try await connect(to: port)
        let second = try await connect(to: port)
        defer {
            first.cancel()
            second.cancel()
        }

        let firstOpen = try await roundTrip(
            .request(id: "first-open", method: "session.open"),
            on: first
        )
        #expect(firstOpen.type == .response)

        let rejected = try await roundTrip(
            .request(id: "second-open", method: "session.open"),
            on: second
        )
        #expect(rejected.type == .error)
        #expect(rejected.error?.code == "device_busy")

        let sessionID = try #require(firstOpen.sessionID)
        let closed = try await roundTrip(
            .request(id: "first-close", method: "session.close", sessionID: sessionID),
            on: first
        )
        #expect(closed.type == .response)

        let reopened = try await roundTrip(
            .request(id: "second-reopen", method: "session.open"),
            on: second
        )
        #expect(reopened.type == .response)
    }

    @Test
    func stoppingPreventsRestartAndClearsPort() async throws {
        let server = try PhoneTCPServer(port: 0, driver: MockPhoneDriver())
        _ = try await server.start()
        server.stop()

        #expect(server.port == nil)
        var restartError: PhoneDriverError?
        do {
            _ = try await server.start()
        } catch let error as PhoneDriverError {
            restartError = error
        } catch {
            Issue.record("unexpected restart error: \(error)")
        }
        #expect(restartError == .transport("TCP listener stopped"))
    }

    private func connect(to port: UInt16) async throws -> NWConnection {
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        try await waitUntilReady(connection)
        return connection
    }

    private func roundTrip(
        _ request: PhoneEnvelope,
        on connection: NWConnection
    ) async throws -> PhoneEnvelope {
        try await send(try PhoneWireCodec().encode(request), on: connection)
        var decoder = PhoneLineDecoder()
        while true {
            let bytes = try await receive(on: connection)
            if let response = try decoder.append(bytes).first {
                return response
            }
        }
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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
