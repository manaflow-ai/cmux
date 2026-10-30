@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The reads a provider asked the app to make.
private actor ReadLog {
    private(set) var reads: [ArtifactsRead] = []
    func add(_ read: ArtifactsRead) { reads.append(read) }
}

private nonisolated struct Offline: Error {}

/// `cmux.artifacts.*`: each op becomes one checked platform GET, and its answer goes back to the
/// page; a file comes back as text with its commit, and a refusal becomes the app's own words.
@MainActor
struct ArtifactsPageProviderTests {
    static let context = PageCallContext(page: PageDescriptor.artifacts.id)
    nonisolated static let tree = #"{"ref":"main","sha":"abc","entries":[{"name":"notes","path":"notes","type":"tree"}]}"#

    private static func provider(_ log: ReadLog, allowed: Bool = true,
                                 answer: @escaping @Sendable (ArtifactsRead) throws -> ArtifactsReply) -> ArtifactsPageProvider {
        ArtifactsPageProvider(allowed: { allowed }) { read in
            await log.add(read)
            return try answer(read)
        }
    }

    @Test func opsBecomeTheExactReads() async throws {
        let log = ReadLog()
        let provider = Self.provider(log) { _ in ArtifactsReply(status: 200, body: Data(Self.tree.utf8)) }
        _ = try await provider.call("cmux.artifacts.tree", params: ["path": "memory/claude"], context: Self.context)
        _ = try await provider.call("cmux.artifacts.tree", params: [:], context: Self.context)
        let historyParams: JSONValue = .object(["path": .string("notes/a.md"), "limit": .number(50)])
        let fileParams: JSONValue = .object(["path": .string("notes/a.md"), "ref": .string("abc")])
        _ = try await provider.call("cmux.artifacts.history", params: historyParams, context: Self.context)
        _ = try await provider.call("cmux.artifacts.file", params: fileParams, context: Self.context)
        let history: [URLQueryItem] = [URLQueryItem(name: "path", value: "notes/a.md"), URLQueryItem(name: "limit", value: "50")]
        let file: [URLQueryItem] = [URLQueryItem(name: "ref", value: "abc"), URLQueryItem(name: "path", value: "notes/a.md")]
        let expected: [ArtifactsRead] = [
            ArtifactsRead(path: "/v1/artifacts/tree", query: [URLQueryItem(name: "path", value: "memory/claude")]),
            ArtifactsRead(path: "/v1/artifacts/tree", query: []),
            ArtifactsRead(path: "/v1/artifacts/history", query: history),
            ArtifactsRead(path: "/v1/artifacts/file", query: file),
        ]
        let reads = await log.reads
        #expect(reads == expected)
    }

    @Test func treeAnswerGoesBackAsIs() async throws {
        let log = ReadLog()
        let provider = Self.provider(log) { _ in ArtifactsReply(status: 200, body: Data(Self.tree.utf8)) }
        let value = try await provider.call("cmux.artifacts.tree", params: [:], context: Self.context)
        #expect(value == (try JSONValue.parse(Data(Self.tree.utf8))))
    }

    @Test func fileComesBackAsTextWithItsCommit() async throws {
        let log = ReadLog()
        let provider = Self.provider(log) { _ in
            ArtifactsReply(status: 200, body: Data("# Notes\n".utf8), contentType: "text/markdown", commit: "abc")
        }
        let file = try await provider.call("cmux.artifacts.file", params: ["path": "notes/a.md"], context: Self.context)
        let expected: JSONValue = .object([
            "path": .string("notes/a.md"), "size": .number(8), "contentType": .string("text/markdown"),
            "commit": .string("abc"), "content": .string("# Notes\n"),
        ])
        #expect(file == expected)
    }

    @Test func bytesThatAreNotTextComeBackAsBase64() async throws {
        let log = ReadLog()
        let bytes = Data([0xFF, 0xD8, 0xFF, 0x00])
        let provider = Self.provider(log) { _ in ArtifactsReply(status: 200, body: bytes, contentType: "image/jpeg", commit: "abc") }
        let file = try await provider.call("cmux.artifacts.file", params: ["path": "a.jpg"], context: Self.context)
        #expect(file["encoding"] == JSONValue.string("base64"))
        #expect(file["content"]?.stringValue == bytes.base64EncodedString())
    }

    @Test func aLargeFileComesBackWithoutContent() async throws {
        let log = ReadLog()
        let body = Data(count: ArtifactsPageProvider.previewLimit + 1)
        let provider = Self.provider(log) { _ in ArtifactsReply(status: 200, body: body) }
        let file = try await provider.call("cmux.artifacts.file", params: ["path": "big.bin"], context: Self.context)
        #expect(file["tooLarge"] == JSONValue.bool(true))
        #expect(file.objectValue?.keys.contains("content") == false)
    }

    /// Each op with params it refuses. Spelled as explicit cases: a literal list of mixed
    /// `JSONValue` literals is too slow for the type checker.
    nonisolated static let badParams: [BadParams] = [
        BadParams(op: "cmux.artifacts.file", params: .object([:])),
        BadParams(op: "cmux.artifacts.file", params: .object(["path": .string("")])),
        BadParams(op: "cmux.artifacts.tree", params: .object(["path": .number(7)])),
        BadParams(op: "cmux.artifacts.tree", params: .object(["ref": .string("main\nHost: evil")])),
        BadParams(op: "cmux.artifacts.history", params: .object(["limit": .number(0)])),
        BadParams(op: "cmux.artifacts.history", params: .object(["limit": .number(101)])),
        BadParams(op: "cmux.artifacts.history", params: .object(["limit": .number(1.5)])),
        BadParams(op: "cmux.artifacts.tree", params: .object(["path": .string(String(repeating: "a", count: 4097))])),
    ]

    @Test(arguments: badParams)
    func badParamsReadNothing(_ bad: BadParams) async throws {
        let op = bad.op
        let params = bad.params
        let log = ReadLog()
        let provider = Self.provider(log) { _ in ArtifactsReply(status: 200, body: Data(Self.tree.utf8)) }
        let error = await #expect(throws: PageError.self) {
            try await provider.call(op, params: params, context: Self.context)
        }
        #expect(error?.code == "cmux.protocol.invalid_params")
        #expect(await log.reads.isEmpty)
    }

    @Test func unknownOpReadsNothing() async throws {
        let log = ReadLog()
        let provider = Self.provider(log) { _ in ArtifactsReply(status: 200, body: Data(Self.tree.utf8)) }
        let error = await #expect(throws: PageError.self) {
            try await provider.call("cmux.artifacts.save", params: [:], context: Self.context)
        }
        #expect(error?.code == "cmux.protocol.unknown_op")
        #expect(await log.reads.isEmpty)
    }

    @Test func previewFeaturesOffReadsNothing() async throws {
        let log = ReadLog()
        let provider = Self.provider(log, allowed: false) { _ in ArtifactsReply(status: 200, body: Data(Self.tree.utf8)) }
        let error = await #expect(throws: PageError.self) {
            try await provider.call("cmux.artifacts.tree", params: [:], context: Self.context)
        }
        #expect(error?.code == "cmux.artifacts.unavailable")
        #expect(error?.message == ArtifactsPageProvider.previewRefusal)
        #expect(await log.reads.isEmpty)
    }

    nonisolated static let refusals: [(Int, String)] = [
        (401, "cmux.artifacts.signed_out"),
        (403, "cmux.artifacts.signed_out"),
        (404, "cmux.artifacts.not_found"),
        (409, "cmux.artifacts.failed"),
        (500, "cmux.artifacts.failed"),
    ]

    @Test(arguments: refusals)
    func refusalsBecomeTheAppsCodes(status: Int, code: String) async throws {
        let log = ReadLog()
        let provider = Self.provider(log) { _ in ArtifactsReply(status: status, body: Data(#"{"secret":"x"}"#.utf8)) }
        let error = await #expect(throws: PageError.self) {
            try await provider.call("cmux.artifacts.tree", params: [:], context: Self.context)
        }
        #expect(error?.code == code)
        #expect(error?.message.contains("secret") == false)
    }

    @Test func anUnreachablePlatformSaysSo() async throws {
        let log = ReadLog()
        let provider = Self.provider(log) { _ in throw Offline() }
        let error = await #expect(throws: PageError.self) {
            try await provider.call("cmux.artifacts.tree", params: [:], context: Self.context)
        }
        #expect(error?.code == "cmux.artifacts.unavailable")
        #expect(error?.retryable == true)
    }

    @Test func aTreeThatIsNotJSONFails() async throws {
        let log = ReadLog()
        let provider = Self.provider(log) { _ in ArtifactsReply(status: 200, body: Data("<html>".utf8)) }
        let error = await #expect(throws: PageError.self) {
            try await provider.call("cmux.artifacts.tree", params: [:], context: Self.context)
        }
        #expect(error?.code == "cmux.artifacts.failed")
    }
}

/// The bearer only ever goes to a platform deployment: an override elsewhere is ignored.
struct ArtifactsAPIBaseTests {
    nonisolated static let platformOverrides: [String] = [
        "https://cmux-platform-development.debussy.workers.dev",
        "https://cmux-platform-staging.debussy.workers.dev/",
        "http://localhost:8787",
        "http://127.0.0.1:8787",
    ]

    @Test(arguments: platformOverrides)
    func platformOverridesApply(text: String) throws {
        let url = try #require(URL(string: text))
        let base = ArtifactsPageProvider.apiBaseURL(environment: ["CMUX_NEXT_ARTIFACTS_API_URL": text])
        #expect(base == url)
    }

    nonisolated static let otherOverrides: [String] = [
        "https://evil.example",
        "http://cmux-platform-development.debussy.workers.dev",
        "https://debussy.workers.dev.evil.example",
        "https://evil.workers.dev",
        "https://user:pw@cmux-platform-development.debussy.workers.dev",
        "https://cmux-platform-development.debussy.workers.dev:8443",
        "http://192.168.1.4:8787",
        "file:///tmp/x",
        "not a url",
    ]

    @Test(arguments: otherOverrides)
    func otherOverridesFallBackToDevelopment(text: String) {
        let base = ArtifactsPageProvider.apiBaseURL(environment: ["CMUX_NEXT_ARTIFACTS_API_URL": text])
        #expect(base == ArtifactsPageProvider.developmentAPI)
    }

    @Test func noOverrideIsDevelopment() {
        #expect(ArtifactsPageProvider.apiBaseURL(environment: [:]) == ArtifactsPageProvider.developmentAPI)
    }

    @Test func readURLKeepsTheBasePathAndOnlyTheReadsQuery() throws {
        let base = try #require(URL(string: "https://cmux-platform-development.debussy.workers.dev/prefix/"))
        let read = ArtifactsRead(path: "/v1/artifacts/file", query: [URLQueryItem(name: "path", value: "a b&c=d")])
        let url = try #require(ArtifactsPageProvider.url(read, base: base))
        #expect(url.absoluteString == "https://cmux-platform-development.debussy.workers.dev/prefix/v1/artifacts/file?path=a%20b%26c%3Dd")
        let injected = ArtifactsRead(path: "/v1/artifacts/tree", query: [URLQueryItem(name: "path", value: "x&ref=evil#y")])
        let other = try #require(ArtifactsPageProvider.url(injected, base: base))
        let items = try #require(URLComponents(url: other, resolvingAgainstBaseURL: false)?.queryItems)
        let expected: [URLQueryItem] = [URLQueryItem(name: "path", value: "x&ref=evil#y")]
        #expect(items == expected)
    }
}

/// One refused call for ``ArtifactsPageProviderTests/badParamsReadNothing(_:)``.
nonisolated struct BadParams: Sendable, CustomTestStringConvertible {
    let op: String
    let params: JSONValue
    var testDescription: String { "\(op) \(params.compactText.prefix(60))" }
}
