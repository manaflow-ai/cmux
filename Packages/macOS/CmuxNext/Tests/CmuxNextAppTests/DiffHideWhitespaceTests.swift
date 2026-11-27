import CmuxNextPages
@testable import CmuxNextDiff
@testable import CmuxNextSettings
import Foundation
import Testing

/// Hide white space in the diff tab's "..." menu (Codex parity D5): the row was always unavailable.
/// The host now names the sidecar option in the page config, passes the page's `ignoreWhitespace`
/// to the sidecar unchanged, and keeps the choice as the `diff.hideWhitespace` setting (off).
@MainActor
@Suite(.serialized)
struct DiffHideWhitespaceTests {
    /// A sidecar that records each request and opens a session.
    actor RecordingSidecar: DiffSidecarRunning {
        private var bodies: [Data] = []

        var requests: [JSONValue] { bodies.compactMap { try? JSONValue.parse($0) } }

        func run(_ request: Data) async throws -> Data {
            bodies.append(request)
            let reply: JSONValue = [
                "id": "reply", "version": 1, "error": .null,
                "result": ["type": "sessionOpened", "value": [
                    "sessionId": "00000000-0000-0000-0000-000000000001",
                    "patch": ["id": "cmux-page://cmux.diff/__patch/t/a.patch", "mediaType": "text/x-diff", "byteLength": 1, "revision": 1],
                    "source": ["kind": "unstaged", "repoRoot": "/Users/dev/uploader"],
                    "generatedPaths": [], "ignoreWhitespace": true,
                ]],
            ]
            return Data(reply.compactText.utf8)
        }
    }

    @Test func theConfigNamesTheSidecarOption() {
        let config = DiffPageConfig.make(repository: DiffRepository(root: "/Users/dev/uploader", branch: "main", base: "main"),
                                         token: "token")
        #expect(config["payload"]?["sessionCapabilities"]?.arrayValue?.contains("session.ignoreWhitespace") == true)
    }

    @Test func aSessionOpenCarriesThePagesChoiceToTheSidecar() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = try DiffSessionGrant.create(root: root, repository: "/Users/dev/uploader")
        defer { grant.remove() }
        let sidecar = RecordingSidecar()
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: sidecar, languages: nil)

        let opened = try await provider.call("cmux.diff.sessionOpen", params: [
            "source": ["kind": "unstaged", "repoRoot": "/Users/dev/uploader"], "capabilityToken": "page", "ignoreWhitespace": true,
        ], context: PageCallContext(page: "cmux.diff"))
        #expect(opened["value"]?["ignoreWhitespace"]?.boolValue == true)
        let params = try #require(await sidecar.requests.first?["params"])
        #expect(params["ignoreWhitespace"]?.boolValue == true)
        // The tab's own token, whatever the page sent.
        #expect(params["capabilityToken"]?.stringValue == grant.token)
        await provider.close()
    }

    @Test func theChoiceIsASettingThatStartsOff() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["diff", "hideWhitespace"]))
        #expect(row.defaultValue == .bool(false))
        #expect(DiffPrefKey.accepts("hideWhitespace", .bool(true)))
        #expect(!DiffPrefKey.accepts("hideWhitespace", .string("yes")))
        #expect(DiffPrefKey.sanitized(.object(["hideWhitespace": .bool(true)]))["hideWhitespace"] == .bool(true))
    }
}
