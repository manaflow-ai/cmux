@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The App Store page's community ops (custom-panes-DESIGN.md section 6.4) from the page call to
/// the registry's HTTP and the supervisor hand-off: signed out is an answer; a submit sends the
/// packed app and needs the sheet; Get hands the approved bundle over only when it is the one
/// asked for; a reviewer's decision needs the sheet; refusals keep their codes. Packing itself is
/// CmuxNextApps' (AppRegistrySubmissionTests).
@MainActor
@Suite(.serialized)
struct AppRegistryPageProviderTests {
    private static let base = URL(string: "https://api.example.test")!

    @Test func signedOutIsAnAnswerAndPublicReadsNeedNoSession() async throws {
        RegistryStub.reset { request in
            request.path == "/v1/apps/registry/listings" ? (200, #"{"listings":[]}"#) : (500, "{}")
        }
        let provider = makeProvider(signedIn: false)
        #expect(try await provider.call("cmux.registry.me", params: [:], context: page()) == ["signedIn": false])
        await #expect(throws: AppRegistryAPI.signedOut) { try await provider.call("cmux.registry.submissions", params: [:], context: page()) }
        let listed = try await provider.call("cmux.registry.listings", params: ["query": "board"], context: page())
        #expect(listed == ["listings": .array([])])
        #expect(RegistryStub.seen.map(\.path) == ["/v1/apps/registry/listings"], "no signed call went out")
        #expect(RegistryStub.seen.first?.query == "query=board")
        #expect(RegistryStub.seen.first?.authorization == nil)
    }

    @Test func aSubmitSendsThePackedAppAfterTheSheet() async throws {
        RegistryStub.reset { _ in (201, #"{"submission":{"id":"sub_00000000000000000001","status":"pending"}}"#) }
        var packed: [(String, String)] = []
        let provider = makeProvider(pack: { app, publisher in
            packed.append((app, publisher))
            return (["id": "octo/board"], ["cmux-app.json": "e30="])
        })
        let params: JSONValue = ["app": "local/board", "publisher": "octo", "notes": "first cut"]
        await #expect(throws: PageError.self) { try await provider.call("cmux.registry.submit", params: params, context: page()) }
        #expect(packed.isEmpty && RegistryStub.seen.isEmpty, "nothing is packed or sent without the sheet")

        let reply = try await provider.call("cmux.registry.submit", params: params, context: page(confirmed: true))
        #expect(reply["submission"]?["status"] == "pending")
        #expect(packed.count == 1 && packed[0] == ("local/board", "octo"))
        let sent = try #require(RegistryStub.seen.first)
        #expect(sent.method == "POST" && sent.path == "/v1/apps/registry/submissions")
        #expect(sent.authorization == "Bearer token-1")
        #expect(sent.body == ["manifest": ["id": "octo/board"], "files": ["cmux-app.json": "e30="], "notes": "first cut"])
    }

    @Test func aPackRefusalIsShownAndNothingIsSent() async throws {
        RegistryStub.reset { _ in (201, "{}") }
        let provider = makeProvider(pack: { _, _ throws(PageError) in
            throw PageError(code: "registry.package", message: "set repository first")
        })
        let error = await #expect(throws: PageError.self) {
            try await provider.call("cmux.registry.submit", params: ["app": "local/board", "publisher": "octo"], context: page(confirmed: true))
        }
        #expect(error?.code == "registry.package")
        #expect(RegistryStub.seen.isEmpty)
    }

    @Test func getHandsTheApprovedBundleToTheSupervisor() async throws {
        RegistryStub.reset { request in
            switch request.path {
            case "/v1/apps/registry/apps/octo/board":
                (200, #"{"app":"octo/board","latest":"1.0.0","versions":[{"version":"1.0.0","sha256":"listed"}]}"#)
            case let path where path.hasSuffix("/octo/board/versions/1.0.0/bundle"):
                (200, #"{"app":"octo/board","version":"1.0.0","sha256":"sent","files":{"cmux-app.json":"e30="}}"#)
            default:
                (200, #"{"app":"octo/other","version":"1.0.0","sha256":"ab","files":{}}"#)
            }
        }
        var puts: [(String, String, String, [String: String])] = []
        let provider = makeProvider(put: { app, version, sha, files in puts.append((app, version, sha, files)) })
        let got = try await provider.call("cmux.registry.get", params: ["app": "octo/board", "version": "1.0.0"], context: page())
        #expect(got == ["app": "octo/board", "version": "1.0.0"])
        #expect(puts.count == 1 && puts[0].0 == "octo/board" && puts[0].2 == "listed" && puts[0].3 == ["cmux-app.json": "e30="])
        #expect(puts.first?.2 == "listed", "the hash the supervisor checks is the listing's, not the bundle's own")
        #expect(RegistryStub.seen.allSatisfy { $0.authorization == nil }, "an approved bundle is public")

        await #expect(throws: PageError.self) {
            try await provider.call("cmux.registry.get", params: ["app": "octo/board", "version": "2.0.0"], context: page())
        }
        await #expect(throws: PageError.self) {
            try await provider.call("cmux.registry.get", params: ["app": "../x", "version": "1.0.0"], context: page())
        }
        #expect(puts.count == 1, "another bundle or a bad id is never handed over")
        #expect(AppRegistryPageProvider.isAppID(publisher: "0x", name: "2048"), "the manifest schema's ids")
        #expect(!AppRegistryPageProvider.isAppID(publisher: String(repeating: "a", count: 40), name: "x"))
    }

    @Test func aReviewersDecisionNeedsTheSheetAndRefusalsKeepTheirCodes() async throws {
        RegistryStub.reset { request in
            switch request.path {
            case "/v1/apps/registry/review/queue":
                (200, #"{"submissions":[{"id":"sub_00000000000000000009","submitter":"user_a","files":[]}]}"#)
            default:
                (409, #"{"error":{"code":"registry.decided","message":"already decided"}}"#)
            }
        }
        let provider = makeProvider()
        let queue = try await provider.call("cmux.registry.review.queue", params: [:], context: page())
        #expect(queue["submissions"]?.arrayValue?.first?["submitter"] == ["user": "user_a"])

        let decide: JSONValue = ["id": "sub_00000000000000000009", "decision": "approve", "reason": "", "app": "octo/board"]
        await #expect(throws: PageError.self) { try await provider.call("cmux.registry.review.decide", params: decide, context: page()) }
        #expect(RegistryStub.seen.count == 1)
        let error = await #expect(throws: PageError.self) {
            try await provider.call("cmux.registry.review.decide", params: decide, context: page(confirmed: true))
        }
        #expect(error?.code == "registry.decided")
        #expect(RegistryStub.seen.last?.body == ["decision": "approve", "reason": ""])
        let confirmation = AppRegistryPageConfirmations.confirmation(op: "cmux.registry.review.decide", params: decide)
        #expect(confirmation?.name.contains("sub_00000000000000000009") == true)
        #expect(confirmation?.name.contains("octo/board") == false, "page-supplied display names cannot disguise the submission being decided")
    }

    // MARK: Fixtures

    private func page(confirmed: Bool = false) -> PageCallContext {
        PageCallContext(page: PageDescriptor.apps.id, origin: confirmed ? "user" : "page", confirmed: confirmed)
    }

    private func makeProvider(signedIn: Bool = true,
                              pack: @escaping AppRegistryPageProvider.Pack = { _, _ in ([:], [:]) },
                              put: @escaping AppRegistryPageProvider.Put = { _, _, _, _ in }) -> AppRegistryPageProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegistryStub.self]
        let api = AppRegistryAPI(baseURL: Self.base, accessToken: {
            guard signedIn else { throw URLError(.userAuthenticationRequired) }
            return "token-1"
        }, session: URLSession(configuration: configuration))
        return AppRegistryPageProvider(api: api, pack: pack, put: put)
    }
}

/// Answers registry requests from a route closure and records each one.
private nonisolated final class RegistryStub: URLProtocol {
    struct Seen: Sendable {
        let method: String
        let path: String
        let query: String?
        let authorization: String?
        let body: JSONValue?
    }

    nonisolated(unsafe) static var seen: [Seen] = []
    nonisolated(unsafe) static var route: (Seen) -> (Int, String) = { _ in (500, "{}") }

    static func reset(_ route: @escaping (Seen) -> (Int, String)) {
        seen = []
        self.route = route
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let data = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let body = data.flatMap { try? JSONValue.parse($0) }
        let seen = Seen(method: request.httpMethod ?? "", path: url.path, query: url.query,
                        authorization: request.value(forHTTPHeaderField: "Authorization"), body: body)
        Self.seen.append(seen)
        let (status, text) = Self.route(seen)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
