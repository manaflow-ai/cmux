import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Leo 2026-10-20: a composer draft's text came back and its pasted screenshots did not, after a
/// quit, after reopening the chat and after archiving or deleting it and restoring it. The page
/// writes its chat's chips (`chat.draftAttachments`) to a folder per chat beside the launch
/// snapshot, and any later page of that chat (a reopened tab, an unarchived or restored chat, the
/// next run after a relaunch or a crash) reads them back (`chat.draftAttachments.get`).
@Suite(.serialized)
@MainActor
struct ChatDraftAttachmentsTests {
    static let context = PageCallContext(page: PageDescriptor.agent.id)
    typealias Chip = AgentPaneWakeState.Attachment

    static func call(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        let provider = AgentPageProvider { _ in nil }
        return try await provider.call(AgentPageOps.namespace + method, params: .object(params), context: context)
    }

    /// Writes chat `session`'s chips as the page does; answers the ids whose contents the host keeps.
    @discardableResult
    static func keep(_ chips: [Chip], for session: String) async throws -> [String] {
        let list = try #require(JSONValue(foundation: try JSONSerialization.jsonObject(with: JSONEncoder().encode(chips))))
        let reply = try await call("chat.draftAttachments", ["sessionId": .string(session), "attachments": list])
        guard case .object(let body) = reply, case .array(let held)? = body["held"] else {
            Issue.record("no held ids in \(reply)")
            return []
        }
        return held.compactMap { value -> String? in
            guard case .string(let id) = value else { return nil }
            return id
        }
    }

    static func kept(_ session: String) async throws -> [Chip] {
        let value = try await call("chat.draftAttachments.get", ["sessionId": .string(session)])
        return try JSONDecoder().decode([Chip].self, from: JSONSerialization.data(withJSONObject: value.foundationObject))
    }

    @discardableResult
    static func keep(_ draft: AgentPaneDraft, for session: String) async throws -> [String] {
        let encoded = AgentPaneDraftAttachments.json(draft)
        let reply = try await call("chat.draftAttachments", ["sessionId": .string(session), "draft": encoded])
        guard case .object(let body) = reply, case .array(let held)? = body["held"] else {
            Issue.record("no held ids in \(reply)")
            return []
        }
        return held.compactMap { value -> String? in
            guard case .string(let id) = value else { return nil }
            return id
        }
    }

    static func ordered(_ session: String) async throws -> AgentPaneDraft {
        let value = try await call("chat.draftAttachments.get", ["sessionId": .string(session), "ordered": .bool(true)])
        return try #require(AgentPaneDraftAttachments.decodeDraft(value))
    }

    /// A Retina screenshot's worth of PNG.
    static func screenshot(_ index: Int) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: UInt8(index), count: 1_500_000)
    }

    static func chip(_ index: Int, contents: Bool = true) -> Chip {
        let bytes = screenshot(index)
        return Chip(id: "shot-\(index)", kind: "image", name: "Screenshot \(index).png", mimeType: "image/png",
                    size: Double(bytes.count), data: contents ? bytes.base64EncodedString() : nil,
                    originalPath: "/session/original/screenshot-\(index).png", originalName: "Screenshot \(index).png")
    }

    static func files(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "draft-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func anInlineDraftKeepsImageTextImageTextOrderOnTheACPWire() {
        let first = Chip(id: "image-1", kind: "image", name: "one.png", mimeType: "image/png", size: 3,
                         data: Data([1, 2, 3]).base64EncodedString())
        let caption = Chip(id: "caption", kind: "text", name: "caption.txt", mimeType: "text/plain", size: 7,
                           text: "describe this")
        let second = Chip(id: "image-2", kind: "image", name: "two.png", mimeType: "image/png", size: 3,
                          data: Data([4, 5, 6]).base64EncodedString())
        let draft = AgentPaneDraft(text: "before\u{FFFC}between\u{FFFC}after\u{FFFC}done",
                                   attachments: [first, caption, second])

        #expect(draft.pieces == [
            .text("before"), .attachment(first), .text("between"), .attachment(caption),
            .text("after"), .attachment(second), .text("done"),
        ])
        let blocks = draft.acpContentBlocks
        #expect(blocks.compactMap { $0["type"]?.stringValue } == ["text", "image", "text", "text", "text", "image", "text"])
        #expect(blocks[0]["text"]?.stringValue == "before")
        #expect(blocks[2]["text"]?.stringValue == "between")
        #expect(blocks[3]["text"]?.stringValue == "caption.txt\n```txt\ndescribe this\n```")
        #expect(blocks[4]["text"]?.stringValue == "after")
        #expect(blocks[5]["type"]?.stringValue == "image")
        #expect(blocks[5]["data"]?.stringValue == Data([4, 5, 6]).base64EncodedString())
        #expect(draft.plainText == "beforebetweenafterdone")
    }

    @Test func anOrderedDraftPersistsItsTextAndAttachmentFilesWithoutChangingTheOldArrayAPI() async throws {
        let directory = try Self.directory()
        defer {
            AgentPaneDraftAttachments.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        AgentPaneDraftAttachments.shared = AgentPaneDraftAttachments(directory: directory)
        let image = Chip(id: "image", kind: "image", name: "image.png", mimeType: "image/png", size: 3,
                         data: Data([7, 8, 9]).base64EncodedString())
        let draft = AgentPaneDraft(text: "look\u{FFFC}now", attachments: [image])
        #expect(try await Self.keep(draft, for: "ordered") == ["image"])

        let restored = try await Self.ordered("ordered")
        #expect(restored.text == draft.text)
        #expect(restored.attachments == draft.attachments)
        #expect(try await Self.kept("ordered") == draft.attachments)
    }

    @Test func aMissingAttachmentFileRemovesOnlyItsMarkAndKeepsLaterMarksAligned() async throws {
        let directory = try Self.directory()
        defer {
            AgentPaneDraftAttachments.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AgentPaneDraftAttachments(directory: directory)
        AgentPaneDraftAttachments.shared = store
        let first = Chip(id: "first", kind: "image", name: "first.png", mimeType: "image/png", size: 3,
                         data: Data([1, 2, 3]).base64EncodedString())
        let missing = Chip(id: "missing", kind: "image", name: "missing.png", mimeType: "image/png", size: 3,
                           data: Data([4, 5, 6]).base64EncodedString())
        let last = Chip(id: "last", kind: "image", name: "last.png", mimeType: "image/png", size: 3,
                        data: Data([7, 8, 9]).base64EncodedString())
        let draft = AgentPaneDraft(text: "one\u{FFFC}caption\u{FFFC}tail", attachments: [first, missing, last])
        #expect(try await Self.keep(draft, for: "repair") == ["first", "last", "missing"])
        let folder = try #require(store.folder(for: "repair"))
        let list = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: AgentPaneDraftAttachments.listName))) as? [String: Any]
        let files = try #require(list?["files"] as? [String: String])
        let missingFile = try #require(files["missing"])
        try FileManager.default.removeItem(at: folder.appending(path: missingFile))

        let restored = try await Self.ordered("repair")
        #expect(restored.attachments.map(\.id) == ["first", "last"])
        #expect(restored.pieces == [.text("one"), .attachment(first), .text("caption"), .attachment(last), .text("tail")])
    }

    @Test func aLegacyAttachmentWriteClearsStaleOrderedText() async throws {
        let directory = try Self.directory()
        defer {
            AgentPaneDraftAttachments.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        AgentPaneDraftAttachments.shared = AgentPaneDraftAttachments(directory: directory)
        let ordered = Chip(id: "ordered", kind: "image", name: "ordered.png", mimeType: "image/png", size: 3,
                           data: Data([1, 2, 3]).base64EncodedString())
        #expect(try await Self.keep(AgentPaneDraft(text: "stale\u{FFFC}text", attachments: [ordered]), for: "legacy") == ["ordered"])
        let replacement = Chip(id: "replacement", kind: "image", name: "replacement.png", mimeType: "image/png", size: 3,
                               data: Data([4, 5, 6]).base64EncodedString())
        #expect(try await Self.keep([replacement], for: "legacy") == ["replacement"])

        let restored = try await Self.ordered("legacy")
        #expect(restored.text.isEmpty)
        #expect(restored.attachments.map(\.id) == ["replacement"])
    }

    @Test func aMalformedOrderedDraftIsRejectedWithoutFallingBackAndErasingIt() async throws {
        let directory = try Self.directory()
        defer {
            AgentPaneDraftAttachments.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        AgentPaneDraftAttachments.shared = AgentPaneDraftAttachments(directory: directory)
        let image = Chip(id: "kept", kind: "image", name: "kept.png", mimeType: "image/png", size: 3,
                         data: Data([1, 2, 3]).base64EncodedString())
        let original = AgentPaneDraft(text: "keep\u{FFFC}this", attachments: [image])
        #expect(try await Self.keep(original, for: "malformed") == ["kept"])
        let malformed = JSONValue.object(["text": .string("bad"), "attachments": .string("not-an-array")])
        await #expect(throws: PageError.self) {
            _ = try await Self.call("chat.draftAttachments", [
                "sessionId": .string("malformed"), "draft": malformed, "attachments": .array([]),
            ])
        }

        let restored = try await Self.ordered("malformed")
        #expect(restored == original)
    }

    @Test func aChatsScreenshotsComeBackWhenItShowsAgainOrTheAppRelaunches() async throws {
        let directory = try Self.directory()
        defer {
            AgentPaneDraftAttachments.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let notes = Chip(id: "link-notes", kind: "link", name: "notes", mimeType: "inode/directory", size: 0, path: "/tmp/notes")

        // This page: four pasted screenshots and an attached folder rest in chat s-1's composer.
        let store = AgentPaneDraftAttachments(directory: directory)
        AgentPaneDraftAttachments.shared = store
        let held = try await Self.keep([1, 2, 3, 4].map { Self.chip($0) } + [notes], for: "s-1")
        // The host says which chips' contents it holds, so the page sends them no more.
        #expect(held == ["shot-1", "shot-2", "shot-3", "shot-4"])
        let folder = try #require(store.folder(for: "s-1"))
        let names = Self.files(in: folder)
        #expect(names.filter { $0.hasSuffix(".png") }.count == 4, "\(names)")
        let list = try Data(contentsOf: folder.appending(path: AgentPaneDraftAttachments.listName))
        #expect(list.count < 16 * 1024, "the screenshots' bytes went into the list")
        let copies = try Set(names.filter { $0.hasSuffix(".png") }.map { try Data(contentsOf: folder.appending(path: $0)) })
        #expect(copies == Set([1, 2, 3, 4].map(Self.screenshot)))

        // The tab closes, or the chat is archived or deleted and its tab with it. A later page of the
        // chat (reopened, unarchived, restored) or the next run after a relaunch or a crash gets them back.
        AgentPaneDraftAttachments.shared = AgentPaneDraftAttachments(directory: directory)
        let back = try await Self.kept("s-1")
        #expect(back.map(\.name) == ["Screenshot 1.png", "Screenshot 2.png", "Screenshot 3.png", "Screenshot 4.png", "notes"])
        #expect(back.prefix(4).map { $0.data.flatMap { Data(base64Encoded: $0) } } == [1, 2, 3, 4].map(Self.screenshot))
        #expect(back.last?.path == "/tmp/notes")
        #expect(back.first?.originalPath == "/session/original/screenshot-1.png")
        #expect(back.first?.originalName == "Screenshot 1.png")
        // Shown again, the chips are still kept: closing that page too loses nothing.
        #expect(try await Self.kept("s-1").count == 5)
        // Another chat gets none of them.
        #expect(try await Self.kept("s-2").isEmpty)

        // Sending them (or taking the last one out) forgets them: no list, no copies.
        try await Self.keep([], for: "s-1")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(try await Self.kept("s-1").isEmpty)
    }

    /// The page sends a chip's contents once; a later write names it without them and the file stays.
    /// A chip taken out loses its file.
    @Test func aChipsContentsAreWrittenOnceAndGoWithIt() async throws {
        let directory = try Self.directory()
        defer {
            AgentPaneDraftAttachments.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AgentPaneDraftAttachments(directory: directory)
        AgentPaneDraftAttachments.shared = store
        let folder = try #require(store.folder(for: "s-1"))
        try await Self.keep([Self.chip(1)], for: "s-1")
        let first = Self.files(in: folder).filter { $0.hasSuffix(".png") }
        try #require(first.count == 1)

        #expect(try await Self.keep([Self.chip(1, contents: false), Self.chip(2)], for: "s-1") == ["shot-1", "shot-2"])
        let both = Self.files(in: folder).filter { $0.hasSuffix(".png") }
        #expect(both.count == 2 && both.contains(first[0]), "the first chip's file was written again: \(both)")
        #expect(try await Self.kept("s-1").map { $0.data.flatMap { Data(base64Encoded: $0) } } == [Self.screenshot(1), Self.screenshot(2)])

        // The first chip taken out: its file goes.
        try await Self.keep([Self.chip(2, contents: false)], for: "s-1")
        let left = Self.files(in: folder).filter { $0.hasSuffix(".png") }
        #expect(left.count == 1 && !left.contains(first[0]))
        #expect(try await Self.kept("s-1").map(\.id) == ["shot-2"])

        // An image the host has no contents for (never sent, its file gone) is not brought back empty,
        // and the host says it holds none, so the page sends its contents next time.
        #expect(try await Self.keep([Self.chip(3, contents: false)], for: "s-1").isEmpty)
        #expect(try await Self.kept("s-1").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func duplicateAttachmentIdsKeepOnlyTheLatestChip() async throws {
        let directory = try Self.directory()
        defer {
            AgentPaneDraftAttachments.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AgentPaneDraftAttachments(directory: directory)
        AgentPaneDraftAttachments.shared = store
        var first = Self.chip(1)
        first.id = "same"
        var latest = Self.chip(2)
        latest.id = "same"

        try await Self.keep([first, latest], for: "s-duplicate")
        let kept = try await Self.kept("s-duplicate")
        #expect(kept.map(\.id) == ["same"])
        #expect(kept.first?.data.flatMap { Data(base64Encoded: $0) } == Self.screenshot(2))
    }

    @Test func aChatPastItsCapKeepsNothingAndBadCallsAreRefused() async throws {
        let directory = try Self.directory()
        defer {
            AgentPaneDraftAttachments.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AgentPaneDraftAttachments(directory: directory)
        store.maximumBytes = 8
        AgentPaneDraftAttachments.shared = store
        let small = Chip(id: "a", kind: "image", name: "a.png", mimeType: "image/png", size: 6, data: Data(repeating: 1, count: 6).base64EncodedString())
        var other = small
        other.id = "b"
        let folder = try #require(store.folder(for: "s-1"))
        try await Self.keep([small, other], for: "s-1")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(try await Self.kept("s-1").isEmpty)
        try await Self.keep([small], for: "s-1")
        #expect(try await Self.kept("s-1").map(\.id) == ["a"])

        await #expect(throws: PageError.self) { _ = try await Self.call("chat.draftAttachments.get", [:]) }
        await #expect(throws: PageError.self) {
            _ = try await Self.call("chat.draftAttachments", ["sessionId": .string("s-1"), "attachments": .string("nope")])
        }
    }
}
