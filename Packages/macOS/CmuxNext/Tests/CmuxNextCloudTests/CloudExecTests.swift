@testable import CmuxNextCloud
import Foundation
import Synchronization
import Testing

/// Records each request's method, path, and exec fields, and answers with `reply`.
final class ExecStubProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable { var method = ""; var path = ""; var command: String?; var timeoutMs: Int? }

    static let seen = Mutex<[Seen]>([])
    static let reply = Mutex("{}")

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.seen.withLock { $0.append(Seen(method: request.httpMethod ?? "", path: request.url?.path ?? "", command: body["command"] as? String, timeoutMs: body["timeoutMs"] as? Int)) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.withLock { $0 }.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct CloudExecTests {
    private static func api() -> CloudAPIClient {
        let configuration = CloudConfiguration.resolve(bundleID: "test.exec", bundled: ["CMUX_VM_API_BASE_URL": "https://exec.test"],
                                                       process: [:], isDebugBuild: true)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ExecStubProtocol.self]
        return CloudAPIClient(configuration: configuration, tokens: { ("a", "r") }, teamID: { nil },
                              session: URLSession(configuration: sessionConfiguration))
    }

    @Test func execPostsTheCommandAndTimeout() async throws {
        ExecStubProtocol.seen.withLock { $0 = [] }
        ExecStubProtocol.reply.withLock { $0 = #"{"exitCode":0,"stdout":"shell: /bin/zsh\n","stderr":""}"# }
        let result = try await Self.api().exec("vm-1", command: "echo hi", timeoutMs: 12_000)
        #expect(result == CloudExecResult(exitCode: 0, stdout: "shell: /bin/zsh\n", stderr: ""))
        let seen = try #require(ExecStubProtocol.seen.withLock { $0.first })
        #expect(seen.method == "POST")
        #expect(seen.path == "/api/vm/vm-1/exec")
        #expect(seen.command == "echo hi")
        #expect(seen.timeoutMs == 12_000)
    }

    @Test func missingExecFieldsDecodeAsEmpty() throws {
        let result = try JSONDecoder().decode(CloudExecResult.self, from: Data(#"{"stdout":"ok"}"#.utf8))
        #expect(result == CloudExecResult(exitCode: -1, stdout: "ok", stderr: ""))
    }
}
