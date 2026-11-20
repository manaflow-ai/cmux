import CmuxNextFiles
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

@MainActor @Suite struct MarkdownSourceUsesTests {
    private final class Host: FilePageHosting {
        var roots: FileWorkspaceRoots { FileWorkspaceRoots(folders: []) }
        var remoteImages = false
        var sourceUses: FilePageSourceContext?
        func recents() -> JSONValue { ["items": []] }
        func record(_: URL) {}
        func chooseFile(start _: URL?) async -> URL? { nil }
        func look() -> JSONValue { .object([:]) }
        func listenLook(_: @escaping @MainActor (JSONValue) -> Void) -> () -> Void { {} }
        func setPreference(key _: String, value _: JSONValue, by _: SettingWriter) async throws {}
        func opened(_: URL) {}
        func openExternal(_: URL) {}
        func openFile(_: URL) {}
        func openAppLink(_: URL) -> Bool { false }
        func isRecent(_: String) -> Bool { false }
        func confirmOpen(_: URL, userGesture _: Bool) async -> Bool { false }
        func edited(_: URL, text _: String, baseHash _: String?, writable _: Bool) -> RecoveryDraftAcceptance { .kept }
        func saved(_: URL, hash _: String) {}
    }


    @Test func fileIdentityMatchesTheRecordedRustURI() throws {
        #expect(FilePageSourceContext.sourceURI(URL(fileURLWithPath: "/tmp/a b/#100%/é.md")) == "file:///tmp/a%20b/%23100%25/%C3%A9.md")
        #expect(FilePageSourceContext.sourceURI(URL(fileURLWithPath: "/tmp/a%20b.md")) == "file:///tmp/a%2520b.md")
        #expect(FilePageSourceContext.sourceURI(try #require(URL(string: "https://example.test/a.md"))) == nil)
    }
    @Test func onlyServedReplyPairsCanOpenAndSessionChangesRevokeThem() async throws {
        let file = URL(fileURLWithPath: "/tmp/source-use.md")
        var current = true
        var revealed: [String] = []
        let source = FilePageSourceContext(file: file, read: { _ in
            ["uses": [["turnId": "turn-1", "replyId": "turn-1.boot.2", "seq": 42]]]
        }, current: { current }, reveal: { reply, seq in #expect(seq == 42); revealed.append(reply); return true })
        #expect(!source.reveal(reply: "turn-1.boot.2", turn: "turn-1"))
        _ = try await source.read(cursor: nil)
        #expect(!source.reveal(reply: "turn-1.boot.2", turn: "other-turn"))
        #expect(source.reveal(reply: "turn-1.boot.2", turn: "turn-1"))
        #expect(revealed == ["turn-1.boot.2"])
        current = false
        #expect(!source.matches(file))
        #expect(!source.reveal(reply: "turn-1.boot.2", turn: "turn-1"))
        await #expect(throws: PageError.self) { _ = try await source.read(cursor: nil) }
    }

    @Test func sessionChangeDuringReadDiscardsTheAnswer() async throws {
        var current = true
        let source = FilePageSourceContext(file: URL(fileURLWithPath: "/tmp/source-use.md"), read: { _ in
            current = false
            return ["uses": [["turnId": "turn-1", "replyId": "turn-1.boot.2", "seq": 42]]]
        }, current: { current }, reveal: { _, _ in Issue.record("stale reply opened"); return true })
        await #expect(throws: PageError.self) { _ = try await source.read(cursor: nil) }
        #expect(!source.reveal(reply: "turn-1.boot.2", turn: "turn-1"))
    }

    @Test func pageCannotQueryAnotherFileOrForgeAReplyClick() async throws {
        let file = URL(fileURLWithPath: "/tmp/source-use.md").standardizedFileURL.resolvingSymlinksInPath()
        let host = Host()
        var calls = 0
        var reveals = 0
        host.sourceUses = FilePageSourceContext(file: file, read: { _ in
            calls += 1
            return ["uses": [["turnId": "turn-1", "replyId": "turn-1.boot.2", "seq": 42]]]
        }, current: { true }, reveal: { _, _ in reveals += 1; return true })
        let provider = FilePageProvider(kind: .markdown, file: file, host: host, libraries: nil, images: GuardedRemoteImages())
        defer { provider.close() }
        let page = PageCallContext(page: FilePageKind.markdown.namespace)
        let click = PageCallContext(page: FilePageKind.markdown.namespace, userGesture: true)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.markdown.sourceUses", params: ["path": "/tmp/other-file.md", "sessionId": "forged"], context: page)
        }
        #expect(calls == 0)
        _ = try await provider.call("cmux.markdown.sourceUses", params: ["path": .string(file.path)], context: page)
        #expect(calls == 1)
        let params: JSONValue = ["path": .string(file.path), "turnId": "turn-1", "replyId": "turn-1.boot.2"]
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.markdown.revealSourceUse", params: params, context: page)
        }
        #expect(reveals == 0)
        _ = try await provider.call("cmux.markdown.revealSourceUse", params: params, context: click)
        #expect(reveals == 1)
        host.sourceUses = nil
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.markdown.sourceUses", params: ["path": .string(file.path)], context: page)
        }
        #expect(calls == 1)
    }
}
