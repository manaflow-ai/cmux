import Foundation
import Testing
@testable import CmuxRemoteConnections

@Suite struct MobileRemoteCmuxProtocolClientTests {
    @Test func negotiatesProtocolAndRoutesRequestsOverChunkedJSONLines() async throws {
        let session = FakeSession()
        let client = MobileRemoteCmuxProtocolClient(session: session)
        try await client.connect()
        #expect(await client.protocolVersion == 12)
        let response = try await client.listWorkspaces()
        #expect(response.objectValue?["workspaces"]?.arrayValue?.count == 1)
        _ = try await client.attachSurface(surface: 7)
        #expect(session.receivedCommands == ["identify", "set-client-info", "list-workspaces", "attach-surface"])
        await client.close()
        #expect(session.closed)
    }

    @Test func refusesAnEndpointWithTheWrongProtocolBeforeUsingIt() async throws {
        let session = FakeSession(protocolVersion: 11)
        let client = MobileRemoteCmuxProtocolClient(session: session)
        await #expect(throws: MobileRemoteCmuxProtocolError.incompatibleServer) {
            try await client.connect()
        }
        #expect(session.closed)
    }

    @Test func boundsAndRejectsMalformedResponses() async throws {
        let session = FakeSession(malformedListResponse: true)
        let client = MobileRemoteCmuxProtocolClient(session: session, maximumFrameBytes: 1_024)
        try await client.connect()
        await #expect(throws: MobileRemoteCmuxProtocolError.malformedFrame) {
            try await client.listWorkspaces()
        }

        let oversized = FakeSession(oversizedResponse: true)
        let bounded = MobileRemoteCmuxProtocolClient(session: oversized, maximumFrameBytes: 128)
        await #expect(throws: MobileRemoteCmuxProtocolError.frameTooLarge) {
            try await bounded.connect()
        }
    }

    @Test func serverErrorDoesNotExposeACommandAsALocalTransportError() async throws {
        let session = FakeSession(serverError: true)
        let client = MobileRemoteCmuxProtocolClient(session: session)
        try await client.connect()
        await #expect(throws: MobileRemoteCmuxProtocolError.server("permission denied")) {
            try await client.listWorkspaces()
        }
    }

    @Test func eofFailsClosed() async throws {
        let session = FakeSession()
        let client = MobileRemoteCmuxProtocolClient(session: session)
        try await client.connect()
        session.finish()
        await #expect(throws: MobileRemoteCmuxProtocolError.unexpectedEOF) {
            try await client.listWorkspaces()
        }
    }

    private final class FakeSession: MobileRemoteSSHSession, @unchecked Sendable {
        let outputStream: AsyncThrowingStream<Data, any Error>
        let continuation: AsyncThrowingStream<Data, any Error>.Continuation
        let protocolVersion: Int
        let malformedListResponse: Bool
        let oversizedResponse: Bool
        let serverError: Bool
        private(set) var receivedCommands: [String] = []
        private(set) var closed = false

        init(
            protocolVersion: Int = 12,
            malformedListResponse: Bool = false,
            oversizedResponse: Bool = false,
            serverError: Bool = false
        ) {
            var continuation: AsyncThrowingStream<Data, any Error>.Continuation!
            self.outputStream = AsyncThrowingStream { continuation = $0 }
            self.continuation = continuation
            self.protocolVersion = protocolVersion
            self.malformedListResponse = malformedListResponse
            self.oversizedResponse = oversizedResponse
            self.serverError = serverError
        }

        func output() -> AsyncThrowingStream<Data, any Error> { outputStream }

        func sendInput(_ data: Data) async throws {
            let frame = try #require(String(data: data, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let json = try #require(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
            let id = try #require(json["id"] as? Int)
            let command = try #require(json["cmd"] as? String)
            receivedCommands.append(command)
            if oversizedResponse {
                continuation.yield(Data(repeating: 0x78, count: 256))
                return
            }
            if command == "list-workspaces", malformedListResponse {
                continuation.yield(Data("{not-json}\n".utf8))
                return
            }
            if command == "list-workspaces", serverError {
                try yield(["id": id, "ok": false, "error": "permission denied"])
                return
            }
            switch command {
            case "identify":
                try yield(["id": id, "ok": true, "data": ["app": "cmux-tui", "protocol": protocolVersion]])
            case "set-client-info":
                try yield(["id": id, "ok": true, "data": [:]])
            case "list-workspaces":
                try yield(["id": id, "ok": true, "data": ["workspaces": [["id": "workspace-1"]]]])
            case "attach-surface":
                try yield(["id": id, "ok": true, "data": ["lease": "lease-1"]])
            default:
                try yield(["id": id, "ok": false, "error": "unknown command"])
            }
        }

        func resize(columns: Int, rows: Int) async throws {}
        func close() async { closed = true; continuation.finish() }
        func finish() { continuation.finish() }

        private func yield(_ object: [String: Any]) throws {
            continuation.yield(try JSONSerialization.data(withJSONObject: object) + Data([0x0A]))
        }
    }
}
