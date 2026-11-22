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

    /// Leo 2026-10-26: attachments take arbitrarily large files of any type, with no size cap. A
    /// chat whose chips held more than 64 MB together kept none of them, so after a quit, a reopen
    /// or a restore from the archive the composer came back empty.
    @Test func chipsPastTheOldBudgetAreKept() async throws {
        let directory = try Self.directory()
        defer {
            AgentPaneDraftAttachments.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        AgentPaneDraftAttachments.shared = AgentPaneDraftAttachments(directory: directory)
        // Two 33 MB recordings: 66 MB together, past the 64 MB a chat used to keep.
        let chips = (1...2).map { index in
            let bytes = Data(repeating: UInt8(index), count: 33 * 1024 * 1024)
            return Chip(id: "big-\(index)", kind: "audio", name: "Recording \(index).m4a", mimeType: "audio/mp4",
                        size: Double(bytes.count), data: bytes.base64EncodedString())
        }
        #expect(try await Self.keep(chips, for: "s-big") == ["big-1", "big-2"], "the chat's chips were not kept")

        // The next run's store reads them back whole.
        AgentPaneDraftAttachments.shared = AgentPaneDraftAttachments(directory: directory)
        let kept = try await Self.kept("s-big")
        #expect(kept.map(\.id) == chips.map(\.id))
        #expect(kept.map(\.data) == chips.map(\.data), "a chip came back without its bytes")
    }

    /// A pasted chip of `count` lines of text, several MB at the default.
    static func pasted(_ id: String, lines count: Int = 300_000) -> Chip {
        let text = (0..<count).map { "pasted line \($0)\n" }.joined()
        return Chip(id: id, kind: "pasted", name: "Pasted text", mimeType: "text/plain", size: Double(text.utf8.count), text: text)
    }

    /// Leo 2026-10-26: attachments take arbitrarily large files of any type. A pasted chip's text
    /// went inline into the chat's list, so a several-MB paste was rewritten into `draft.json` on
    /// every settle. Its text is a file of its own beside the list now, read back when the chat shows.
    @Test func aLargePastedTextChipComesBackAfterARelaunch() async throws {
        let directory = try Self.directory()
        defer {
            AgentPaneDraftAttachments.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AgentPaneDraftAttachments(directory: directory)
        AgentPaneDraftAttachments.shared = store
        let paste = Self.pasted("paste-1")
        try #require(paste.text!.utf8.count > 5_000_000)
        let notes = Chip(id: "link-notes", kind: "link", name: "notes", mimeType: "inode/directory", size: 0, path: "/tmp/notes")
        #expect(try await Self.keep([paste, notes], for: "s-paste") == ["paste-1"], "the host did not say it holds the paste's text")

        let folder = try #require(store.folder(for: "s-paste"))
        let names = Self.files(in: folder)
        #expect(names.filter { $0.hasSuffix(".txt") }.count == 1, "the paste's text is not a file of its own: \(names)")
        let list = try Data(contentsOf: folder.appending(path: AgentPaneDraftAttachments.listName))
        #expect(list.count < 16 * 1024, "the paste's text went into the list (\(list.count) bytes)")
        #expect(list.range(of: Data("pasted line 12345".utf8)) == nil, "the list holds the paste's text")

        // The next run's store reads it back whole.
        AgentPaneDraftAttachments.shared = AgentPaneDraftAttachments(directory: directory)
        let back = try await Self.kept("s-paste")
        #expect(back.map(\.id) == ["paste-1", "link-notes"])
        #expect(back.first?.text == paste.text, "the paste came back without its text")
        #expect(back.first?.kind == "pasted")
        #expect(back.last?.path == "/tmp/notes")
    }

    /// A list an older build wrote, a pasted chip's text inline, still comes back.
    @Test func anOldListWithInlineTextStillComesBack() async throws {
        let directory = try Self.directory()
        defer {
            AgentPaneDraftAttachments.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AgentPaneDraftAttachments(directory: directory)
        AgentPaneDraftAttachments.shared = store
        let folder = try #require(store.folder(for: "s-old"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paste = Self.pasted("paste-old", lines: 3)
        let log = Chip(id: "log", kind: "text", name: "build.log", mimeType: "text/plain", size: 3, text: "ok\n")
        let chips = try JSONSerialization.jsonObject(with: JSONEncoder().encode([paste, log]))
        try JSONSerialization.data(withJSONObject: ["attachments": chips])
            .write(to: folder.appending(path: AgentPaneDraftAttachments.listName))

        let back = try await Self.kept("s-old")
        #expect(back == [paste, log], "a list the last build wrote did not come back")
    }

    /// A pasted chip taken out loses its text's file; one sent again without its text keeps it.
    @Test func aPastedChipsTextFileGoesWithIt() async throws {
        let directory = try Self.directory()
        defer {
            AgentPaneDraftAttachments.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AgentPaneDraftAttachments(directory: directory)
        AgentPaneDraftAttachments.shared = store
        let folder = try #require(store.folder(for: "s-1"))
        let first = Self.pasted("paste-1", lines: 1000)
        let second = Self.pasted("paste-2", lines: 2000)
        try await Self.keep([first, second, Self.chip(1)], for: "s-1")
        let both = Self.files(in: folder).filter { $0.hasSuffix(".txt") }
        try #require(both.count == 2, "\(Self.files(in: folder))")

        // A chip named again without its text keeps the file it has.
        var bare = second
        bare.text = nil
        try await Self.keep([bare, Self.chip(1, contents: false)], for: "s-1")
        let left = Self.files(in: folder).filter { $0.hasSuffix(".txt") }
        #expect(left.count == 1, "the removed paste's text file stayed: \(left)")
        #expect(Self.files(in: folder).filter { $0.hasSuffix(".png") }.count == 1)
        let back = try await Self.kept("s-1")
        #expect(back.map(\.id) == ["paste-2", "shot-1"])
        #expect(back.first?.text == second.text)

        // The last chips taken out: the folder goes with every file in it.
        try await Self.keep([], for: "s-1")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func badCallsAreRefused() async throws {
        let directory = try Self.directory()
        defer {
            AgentPaneDraftAttachments.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        AgentPaneDraftAttachments.shared = AgentPaneDraftAttachments(directory: directory)

        await #expect(throws: PageError.self) { _ = try await Self.call("chat.draftAttachments.get", [:]) }
        await #expect(throws: PageError.self) {
            _ = try await Self.call("chat.draftAttachments", ["sessionId": .string("s-1"), "attachments": .string("nope")])
        }
    }
}
