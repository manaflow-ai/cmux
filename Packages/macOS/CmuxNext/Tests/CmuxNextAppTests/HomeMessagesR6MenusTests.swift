import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Review round 6 of cmux#37736, package "menus": the app side of a transcript bubble's menu
/// (``HomeMessagesBubbleOps``, the native transcript's PaneMenu rows the page cannot run itself):
/// what it offers per conversation, Retry Reply only for a Chief this app's brain answers, Forward…
/// through Send To…, and no run without the person's click.
@MainActor @Suite(.serialized)
struct HomeMessagesR6MenusTests {
    private final class Record {
        var retried: [(ConversationID, String)] = []
        var forwarded: [String] = []
        var opened: [URL] = []
    }

    private func ops(_ record: Record, hosted: Set<String> = []) -> HomeMessagesBubbleOps {
        HomeMessagesBubbleOps(store: HomeStore(source: MockHomeSource(options: .immediate)), host: .init(
            linkScheme: "cmux-dev-menus",
            retryReply: { id -> (@MainActor (String) async -> Bool)? in
                if hosted.contains(id.rawValue) { return nil }
                return { message in
                    record.retried.append((id, message))
                    return true
                }
            },
            forward: { record.forwarded.append($0); return true },
            openFile: { record.opened.append($0) },
            fileMenu: { _, _ in [] }))
    }

    private static let click: PageError? = nil
    private static let noClick = PageError(code: "cmux.app.user_only", message: "a click only")

    /// The facts the page builds its rows from: the build's scheme, Retry Reply only off a hosted Chief.
    @Test func factsOfferRetryReplyOnlyForAChiefThisAppsBrainAnswers() async throws {
        let ops = ops(Record(), hosted: ["conv_hosted"])
        let local = try #require(try await ops.call("bubble.facts", ["conversation": .string("conv_local")], refusal: Self.noClick))
        #expect(local.objectValue?["linkScheme"]?.stringValue == "cmux-dev-menus")
        #expect(local.objectValue?["retryReply"]?.boolValue == true)
        #expect(local.objectValue?["forward"]?.boolValue == true)
        let hosted = try #require(try await ops.call("bubble.facts", ["conversation": .string("conv_hosted")], refusal: nil))
        #expect(hosted.objectValue?["retryReply"]?.boolValue == false, "a Cloud-hosted Chief has no Retry Reply (HomeChiefTurnActions)")
    }

    /// Retry Reply runs `chief.retry` on the message; a hosted Chief's runs nothing.
    @Test func retryReplyRetriesTheMessageOnTheConversationsChief() async throws {
        let record = Record()
        let ops = ops(record, hosted: ["conv_hosted"])
        let ran = try await ops.call("bubble.retryReply", ["conversation": .string("conv_local"), "message": .string("msg_1")], refusal: Self.click)
        #expect(ran?.objectValue?["ran"]?.boolValue == true)
        #expect(record.retried.map(\.0.rawValue) == ["conv_local"])
        #expect(record.retried.map(\.1) == ["msg_1"])
        let hosted = try await ops.call("bubble.retryReply", ["conversation": .string("conv_hosted"), "message": .string("msg_1")], refusal: Self.click)
        #expect(hosted?.objectValue?["ran"]?.boolValue == false)
        #expect(record.retried.count == 1)
    }

    /// Every run but `facts` is the person's click only; another op is not this one's.
    @Test func runsWithoutAClickAreRefused() async throws {
        let record = Record()
        let ops = ops(record)
        await #expect(throws: PageError.self) {
            _ = try await ops.call("bubble.forward", ["text": .string("hi")], refusal: Self.noClick)
        }
        await #expect(throws: PageError.self) {
            _ = try await ops.call("bubble.retryReply", ["conversation": .string("c"), "message": .string("m")], refusal: Self.noClick)
        }
        #expect(record.forwarded.isEmpty && record.retried.isEmpty)
        #expect(try await ops.call("drafts.load", [:], refusal: nil) == nil)
        _ = try await ops.call("bubble.forward", ["text": .string("hi")], refusal: Self.click)
        #expect(record.forwarded == ["hi"], "Forward… goes to Send To… with the bubble's text")
    }

    /// Share… takes text or a web link, never another scheme; a file row takes an absolute path or
    /// an attachment, and runs the host's opener on it.
    @Test func shareAndFileRowsCheckWhatTheyAreGiven() async throws {
        #expect(HomeMessagesBubbleOps.shareItem(["url": .string("https://example.com")]) as? URL == URL(string: "https://example.com"))
        #expect(HomeMessagesBubbleOps.shareItem(["url": .string("file:///etc/passwd")]) == nil)
        #expect(HomeMessagesBubbleOps.shareItem(["text": .string("hello")]) as? String == "hello")
        let record = Record()
        let ops = ops(record)
        await #expect(throws: PageError.self) {
            _ = try await ops.call("bubble.file", ["action": .string("open"), "path": .string("relative/a.md")], refusal: Self.click)
        }
        await #expect(throws: PageError.self) {
            _ = try await ops.call("bubble.file", ["action": .string("rm"), "path": .string("/tmp/a.md")], refusal: Self.click)
        }
        _ = try await ops.call("bubble.file", ["action": .string("open"), "path": .string("/tmp/a.md")], refusal: Self.click)
        #expect(record.opened == [URL(fileURLWithPath: "/tmp/a.md")])
    }

    /// Save As… copies the bytes over an older file there; an attachment's copy is named like it.
    @Test func saveAsReplacesAndTheNamedCopyKeepsTheAttachmentsName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r6-menus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blob = root.appendingPathComponent("abc123")
        try Data("new".utf8).write(to: blob)
        let destination = root.appendingPathComponent("saved.txt")
        try Data("old".utf8).write(to: destination)
        try HomeMessagesBubbleOps.save(blob, to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
        let hash = "r6menus-\(UUID().uuidString)"
        let named = try HomeMessagesBubbleOps.namedCopy(of: blob, name: "../report.pdf", hash: hash)
        defer { try? FileManager.default.removeItem(at: named.deletingLastPathComponent()) }
        #expect(named.lastPathComponent == "report.pdf", "only the name's last component, never a path out of its folder")
        #expect(try Data(contentsOf: named) == Data("new".utf8))
    }
}
