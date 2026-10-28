import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextDiff
import Foundation
import Testing

/// Load full files in the diff tab's "..." menu (Codex parity): the page asks the sidecar for a
/// file's two sides (`fileContents`). The host names the sidecar option in the page config and
/// passes the request through only for one of the tab's own sessions, with the tab's token.
@MainActor
@Suite(.serialized)
struct DiffFileContentsTests {
    /// A sidecar that records each request; it opens a session, then answers a file's sides.
    actor RecordingSidecar: DiffSidecarRunning {
        private var bodies: [Data] = []

        var requests: [JSONValue] { bodies.compactMap { try? JSONValue.parse($0) } }

        func run(_ request: Data) async throws -> Data {
            bodies.append(request)
            let method = (try? JSONValue.parse(request))?["method"]?.stringValue
            let result: JSONValue = method == "fileContents"
                ? ["type": "fileContents", "value": [
                    "old": ["contents": "row 1\n", "encoding": "text"],
                    "new": ["contents": "row one\n", "encoding": "text"],
                ]]
                : ["type": "sessionOpened", "value": [
                    "sessionId": "00000000-0000-0000-0000-000000000001",
                    "patch": ["id": "cmux-page://cmux.diff/__patch/t/a.patch", "mediaType": "text/x-diff",
                              "byteLength": 1, "revision": 1],
                    "source": ["kind": "unstaged", "repoRoot": "/Users/dev/uploader"],
                    "generatedPaths": [],
                ]]
            let reply: JSONValue = ["id": "reply", "version": 1, "error": .null, "result": result]
            return Data(reply.compactText.utf8)
        }
    }

    @Test func theConfigNamesTheSidecarOption() {
        let config = DiffPageConfig.make(repository: DiffRepository(root: "/Users/dev/uploader", branch: "main", base: "main"),
                                         token: "token")
        #expect(config["payload"]?["sessionCapabilities"]?.arrayValue?.contains("session.fileContents") == true)
    }

    @Test func onlyTheTabsOwnSessionsReadFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = try DiffSessionGrant.create(root: root, repository: "/Users/dev/uploader")
        defer { grant.remove() }
        let sidecar = RecordingSidecar()
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: sidecar, languages: nil)
        let context = PageCallContext(page: "cmux.diff")

        // A session the tab never opened: refused before the sidecar.
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.fileContents", params: [
                "sessionId": "00000000-0000-0000-0000-000000000009", "path": "a.txt",
            ], context: context)
        }
        #expect(await sidecar.requests.isEmpty)

        let opened = try await provider.call("cmux.diff.sessionOpen", params: [
            "source": ["kind": "unstaged", "repoRoot": "/Users/dev/uploader"], "capabilityToken": "page",
        ], context: context)
        let session = try #require(opened["value"]?["sessionId"]?.stringValue)
        let sides = try await provider.call("cmux.diff.fileContents", params: [
            "sessionId": .string(session), "path": "a.txt", "capabilityToken": "page",
        ], context: context)
        #expect(sides["value"]?["new"]?["contents"]?.stringValue == "row one\n")
        let params = try #require(await sidecar.requests.last?["params"])
        #expect(params["path"]?.stringValue == "a.txt")
        // The tab's own token, whatever the page sent.
        #expect(params["capabilityToken"]?.stringValue == grant.token)
        await provider.close()
    }
}
