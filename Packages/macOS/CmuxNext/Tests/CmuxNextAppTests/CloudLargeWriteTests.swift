@testable import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// A daemon request is at most 4 MiB, so a machine write whose base64 is larger goes to the route
/// itself, with the headers the daemon's call would send: every write the route took before the
/// calls moved to the daemon still goes.
@Suite(.serialized) struct CloudLargeWriteTests {
    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WriteRouteProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func aClassicWriteTooLargeForTheDaemonPostsToTheRoute() async throws {
        WriteRouteProtocol.reset()
        let fake = FakeCloudAPI()
        var api = fake.classic()
        api.fileRoute = Self.session()
        let big = Data(repeating: 7, count: 4 << 20)
        try await api.writeFile("vm_abcdefghij0123456789", path: "/a", data: big, mode: 0o640)
        #expect(fake.seen.isEmpty, "the daemon never gets a request past its limit")
        let sent = try #require(WriteRouteProtocol.requests.first)
        #expect(sent.url?.path == "/api/vm/vm_abcdefghij0123456789/fs/write")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(sent.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh")
        #expect(sent.value(forHTTPHeaderField: "X-Cmux-Team-Id") == "team-1")
        let body = try #require(try JSONSerialization.jsonObject(with: WriteRouteProtocol.bodies.first ?? Data()) as? [String: Any])
        #expect(body["dataBase64"] as? String == big.base64EncodedString())
        #expect(body["mode"] as? Int == 0o640)
    }

    @Test func aWorkerWriteTooLargeForTheDaemonPostsToTheWorkerRoute() async throws {
        WriteRouteProtocol.reset()
        let fake = FakeCloudAPI()
        var api = fake.worker()
        api.fileRoute = Self.session()
        try await api.writeFile("vm_abcdefghij0123456789", path: "/a", data: Data(repeating: 1, count: 4 << 20))
        #expect(fake.seen.isEmpty)
        let sent = try #require(WriteRouteProtocol.requests.first)
        #expect(sent.url?.path == "/v1/cloud/machines/vm_abcdefghij0123456789/fs/write")
        #expect(sent.value(forHTTPHeaderField: "x-cmux-team") == "team_cmux")
        #expect(sent.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == nil, "a Worker client never sends the refresh token")
    }

    @Test func aReadTooLargeForOneDaemonAnswerGoesToTheRoute() async throws {
        WriteRouteProtocol.reset()
        let fake = FakeCloudAPI { _ in throw FakeCloudAPI.refusal(#"{"kind":"transport","message":"the answer is larger than the reply limit (16711680 bytes)"}"#) }
        var api = fake.classic()
        api.fileRoute = Self.session()
        let contents = try await api.readFile("vm_abcdefghij0123456789", path: "/big file")
        #expect(contents.dataBase64 == "aGk=")
        #expect(fake.operations == ["cloud.machine.io"], "the daemon is asked first")
        let sent = try #require(WriteRouteProtocol.requests.first)
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.path == "/api/vm/vm_abcdefghij0123456789/fs/read")
        #expect(sent.url?.query == "path=/big%20file")
        #expect(sent.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh")
    }

    @Test func anyOtherReadRefusalIsNotSentAgain() async {
        WriteRouteProtocol.reset()
        let fake = FakeCloudAPI { _ in throw FakeCloudAPI.refusal(#"{"kind":"transport","message":"offline"}"#) }
        var api = fake.classic()
        api.fileRoute = Self.session()
        await #expect(throws: CloudAPIError.transport("offline")) { _ = try await api.readFile("vm_abcdefghij0123456789", path: "/a") }
        #expect(WriteRouteProtocol.requests.isEmpty)
    }

    @Test func aWriteThatFitsGoesThroughTheDaemon() async throws {
        WriteRouteProtocol.reset()
        let fake = FakeCloudAPI()
        var api = fake.classic()
        api.fileRoute = Self.session()
        try await api.writeFile("vm_abcdefghij0123456789", path: "/a", data: Data(repeating: 1, count: 1 << 20))
        #expect(fake.operations == ["cloud.machine.io"])
        #expect(WriteRouteProtocol.requests.isEmpty)
    }
}

/// Answers every request 200 and keeps what was sent.
private nonisolated final class WriteRouteProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var sent: [(URLRequest, Data)] = []
    static var requests: [URLRequest] { lock.withLock { sent.map(\.0) } }
    static var bodies: [Data] { lock.withLock { sent.map(\.1) } }
    static func reset() { lock.withLock { sent = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 { body.append(buffer, count: count) }
            stream.close()
        }
        Self.lock.withLock { Self.sent.append((request, body)) }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true,"path":"/a","dataBase64":"aGk=","size":2}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
