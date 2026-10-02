@testable import CmuxNextCloud
import Foundation
import Synchronization
import Testing

final class CloudFileStubProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable { var method: String; var path: String; var query: String?; var body: [String: Any] }
    static let seen = Mutex<[Seen]>([])
    static let reply = Mutex(Data("{}".utf8))

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let bodyData = request.httpBody ?? Data()
        let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        Self.seen.withLock { $0.append(Seen(method: request.httpMethod ?? "", path: request.url?.path ?? "", query: request.url?.query, body: body)) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.reply.withLock { $0 })
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct CloudFileAPITests {
    private static func api() -> CloudAPIClient {
        let configuration = CloudConfiguration.resolve(bundleID: "test.files", bundled: ["CMUX_VM_API_BASE_URL": "https://files.test"], process: [:], isDebugBuild: true)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CloudFileStubProtocol.self]
        return CloudAPIClient(configuration: configuration, tokens: { ("a", "r") }, teamID: { nil },
                              session: URLSession(configuration: sessionConfiguration))
    }

    @Test func listsAndReadsEncodedPaths() async throws {
        CloudFileStubProtocol.seen.withLock { $0 = [] }
        CloudFileStubProtocol.reply.withLock { $0 = Data(#"{"entries":[{"name":"notes.txt","kind":"file","size":4}]}"#.utf8) }
        let entries = try await Self.api().listFiles("vm-1", path: "/work/a&b?c=1")
        #expect(entries == [CloudFileEntry(name: "notes.txt", kind: "file", size: 4)])
        CloudFileStubProtocol.reply.withLock { $0 = Data(#"{"path":"/work notes/notes.txt","dataBase64":"aGkK","size":3}"#.utf8) }
        let contents = try await Self.api().readFile("vm-1", path: "/work notes/notes.txt")
        #expect(contents.text == "hi\n")
        let seen = CloudFileStubProtocol.seen.withLock { $0 }
        #expect(seen[0].path == "/api/vm/vm-1/fs/dir")
        #expect(seen[0].query?.contains("path=/work/a%26b%3Fc%3D1") == true)
        #expect(seen[1].path == "/api/vm/vm-1/fs/read")
    }

    @Test func writesAndMutatesFilesThroughTypedRoutes() async throws {
        CloudFileStubProtocol.seen.withLock { $0 = [] }
        CloudFileStubProtocol.reply.withLock { $0 = Data("{}".utf8) }
        try await Self.api().writeFile("vm-1", path: "/tmp/hello", data: Data("hello".utf8), mode: 0o600)
        try await Self.api().makeDirectory("vm-1", path: "/tmp/new")
        try await Self.api().removeFile("vm-1", path: "/tmp/old")
        let statReply = Data(#"{"path":"/tmp/hello","kind":"file","size":5,"mode":384}"#.utf8)
        CloudFileStubProtocol.reply.withLock { $0 = statReply }
        let stat = try await Self.api().statFile("vm-1", path: "/tmp/hello")
        #expect(stat.kind == "file")
        #expect(stat.mode == 0o600)
        let seen = CloudFileStubProtocol.seen.withLock { $0 }
        #expect(seen.map(\.method) == ["POST", "POST", "DELETE", "GET"])
        #expect(seen[0].body["path"] as? String == "/tmp/hello")
        #expect(seen[0].body["dataBase64"] as? String == Data("hello".utf8).base64EncodedString())
    }

    @Test func validatesTheShortLivedScpEndpoint() async throws {
        CloudFileStubProtocol.seen.withLock { $0 = [] }
        CloudFileStubProtocol.reply.withLock { $0 = Data(#"{"host":"10.16.0.5","port":22,"username":"cmux","hostPublicKey":"ssh-ed25519 AAAA","expiresAtUnix":4102444800}"#.utf8) }
        let endpoint = try await Self.api().prepareSCP("vm-1", publicKey: "ssh-ed25519 AAAA client")
        #expect(endpoint.port == 22)
        #expect(endpoint.username == "cmux")
        #expect(CloudFileStubProtocol.seen.withLock { $0.first?.path } == "/api/vm/vm-1/scp-endpoint")
    }

    @Test func rejectsUnsafeScpEndpoint() async throws {
        CloudFileStubProtocol.reply.withLock { $0 = Data(#"{"host":"public.example","port":22,"username":"cmux","hostPublicKey":"ssh-rsa AAAA","expiresAtUnix":4102444800}"#.utf8) }
        await #expect(throws: CloudAPIError.self) { try await Self.api().prepareSCP("vm-1", publicKey: "ssh-ed25519 AAAA client") }
    }
}
