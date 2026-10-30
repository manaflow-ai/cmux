import CmuxNextPages
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
        _ = try await provider.call("cmux.artifacts.history", params: ["path": "notes/a.md", "limit": 50], context: Self.context)
        _ = try await provider.call("cmux.artifacts.file", params: ["path": "notes/a.md", "ref": "abc"], context: Self.context)
        #expect(await log.reads == [
            ArtifactsRead(path: "/v1/artifacts/tree", query: [URLQueryItem(name: "path", value: "memory/claude")]),
            ArtifactsRead(path: "/v1/artifacts/tree", query: []),
            ArtifactsRead(path: "/v1/artifacts/history", query: [URLQueryItem(name: "path", value: "notes/a.md"),
                                                                 URLQueryItem(name: "limit", value: "50")]),
            ArtifactsRead(path: "/v1/artifacts/file", query: [URLQueryItem(name: "ref", value: "abc"),
                                                              URLQueryItem(name: "path", value: "notes/a.md")]),
        ])
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
        #expect(file == ["path": "notes/a.md", "size": 8, "contentType": "text/markdown", "commit": "abc", "content": "# Notes\n"])
    }

    @Test func bytesThatAreNotTextComeBackAsBase64() async throws {
        let log = ReadLog()
        let bytes = Data([0xFF, 0xD8, 0xFF, 0x00])
        let provider = Self.provider(log) { _ in ArtifactsReply(status: 200, body: bytes, contentType: "image/jpeg", commit: "abc") }
        let file = try await provider.call("cmux.artifacts.file", params: ["path": "a.jpg"], context: Self.context)
        #expect(file["encoding"] == "base64")
        #expect(file["content"]?.stringValue == bytes.base64EncodedString())
    }

    @Test func aLargeFileComesBackWithoutContent() async throws {
        let log = ReadLog()
        let body = Data(count: ArtifactsPageProvider.previewLimit + 1)
        let provider = Self.provider(log) { _ in ArtifactsReply(status: 200, body: body) }
        let file = try await provider.call("cmux.artifacts.file", params: ["path": "big.bin"], context: Self.context)
        #expect(file["tooLarge"] == true)
        #expect(file.objectValue?.keys.contains("content") == false)
    }

    @Test(arguments: [
        ("cmux.artifacts.file", [:] as JSONValue),
        ("cmux.artifacts.file", ["path": ""]),
        ("cmux.artifacts.tree", ["path": 7]),
        ("cmux.artifacts.tree", ["ref": "main\nHost: evil"]),
        ("cmux.artifacts.history", ["limit": 0]),
        ("cmux.artifacts.history", ["limit": 101]),
        ("cmux.artifacts.history", ["limit": 1.5]),
        ("cmux.artifacts.tree", ["path": .string(String(repeating: "a", count: 4097))]),
    ])
    func badParamsReadNothing(op: String, params: JSONValue) async throws {
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

    @Test(arguments: [
        (401, "cmux.artifacts.signed_out"),
        (403, "cmux.artifacts.signed_out"),
        (404, "cmux.artifacts.not_found"),
        (409, "cmux.artifacts.failed"),
        (500, "cmux.artifacts.failed"),
    ])
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
