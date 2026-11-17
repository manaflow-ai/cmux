import AppKit
import CmuxHomeCore
import CmuxNextHome
import CmuxNextHomeModel
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Observation
import Testing

/// Review round 10 of cmux#37736: a sent file's kept bytes belong to the outbox until its send is
/// delivered or discarded, so a send that fails and a relaunch still find them for Retry (F2); New
/// Message's first send selects its conversation only once its outcome is known, so the page's
/// selection watch never opens it over a refusal (F4); the app's files (Attach Files, `cmux home
/// attach`, a viewer quote, a browser highlight) reach the Messages page's composer (F1).
@MainActor @Suite(.serialized)
struct HomeMessagesR10Tests {
    static let hash = String(repeating: "cd", count: 32)

    @Test func aSentFilesBytesStayWithTheOutboxUntilTheSendLeaves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-messages-r10-outbox-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appending(path: "blobs"))
        store.start()
        defer { store.stop() }
        let id = HomeChiefRosterTests.ada
        let kept = HomeMessagesKept(store: store, keepLocation: { false })
        let bytes = Data("notes".utf8)
        let part = HomeMessagesR6AttachmentsTests.part(Self.hash, byteCount: bytes.count)
        _ = try await kept.call("attachments.put", ["conversation": .string(id.rawValue), "part": part, "at": .number(1)])
        _ = try await kept.call("attachments.write", ["hash": .string(Self.hash), "offset": .number(0),
                                                      "byteCount": .number(Double(bytes.count)),
                                                      "data": .string(bytes.base64EncodedString())])
        let file = HomeMessagesAttachmentDrafts(store: store).fileURL(Self.hash)

        // The send that took the file is kept, then its tray entry goes: the bytes stay.
        _ = try await kept.call("outbox.put", ["conversation": .string(id.rawValue), "send": .object([
            "key": .string("k1"), "conversation": .string(id.rawValue), "text": .string(""),
            "createdAt": .number(1), "failed": .bool(true), "attachments": .array([part]),
        ])])
        _ = try await kept.call("attachments.remove", ["conversation": .string(id.rawValue), "hash": .string(Self.hash)])
        #expect(FileManager.default.fileExists(atPath: file.path), "the outbox's send still names the file")

        // A relaunch's load keeps them too (they are not an orphan), and they read back.
        _ = try await kept.call("attachments.load", [:])
        #expect(FileManager.default.fileExists(atPath: file.path))
        let read = try #require(try await kept.call("attachments.read", ["hash": .string(Self.hash), "offset": .number(0),
                                                                         "length": .number(Double(bytes.count))]))
        #expect(read.value(at: ["data"])?.stringValue.flatMap { Data(base64Encoded: $0) } == bytes)

        // Delivered or discarded: the bytes go with the send.
        _ = try await kept.call("outbox.remove", ["conversation": .string(id.rawValue), "key": .string("k1")])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// HomeService's pending selection, as the page's watch reads it.
    @Observable @MainActor final class Pending {
        var selection: ConversationID?
    }

    /// F4: a refused first send never reaches the page's selection watch (New Message keeps its
    /// people, text and refusal); an opened one does, after its outcome.
    @Test func theFirstSendSelectsOnlyAfterItsOutcome() async throws {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source, blobCacheDirectory: try HomeMessagesR6NewMessageTests.directory())
        store.start()
        defer { store.stop() }
        await HomeMessagesR6NewMessageTests.until { store.isOnline && !store.rows.isEmpty }
        let id = try #require(store.rows.first?.id)
        let pending = Pending()
        var shown: [ConversationID] = []
        let watch = HomeMessagesSelectionWatch(pending: { pending.selection }, spend: { pending.selection = nil },
                                               rows: { store.rows.map(\.id) }).follow { shown.append($0) }
        defer { watch.cancel() }
        var startedSelection: ConversationID?
        let send = HomeMessagesFirstSend(store: store, contacts: [HomeMessagesR6NewMessageTests.ada],
                                         start: { _, _ in .opened(id) },
                                         refusal: { _, _ in
                                             startedSelection = pending.selection
                                             return .refused("Too long")
                                         },
                                         select: { pending.selection = $0 })

        let refusedKey = IdempotencyKey("r10-first-send-refused")
        await source.failNextSubmits(of: refusedKey, times: 1, with: .invalid("message.too_long"))
        let refused = await send.run(HomeMessagesR6NewMessageTests.fields(text: "hello"), key: refusedKey)
        #expect(refused == HomeComposeOutcome.refused("Too long").pageOutcome)
        #expect(startedSelection == nil, "nothing was selected while the send was out")
        for _ in 0..<200 { await Task.yield() }
        #expect(shown.isEmpty, "the watch never opened the conversation over New Message's refusal")
        #expect(pending.selection == nil)

        let opened = await send.run(HomeMessagesR6NewMessageTests.fields(text: "hello"), key: IdempotencyKey("r10-first-send-ok"))
        #expect(opened.value(at: ["outcome", "kind"]) == .string("opened"))
        await HomeMessagesR6NewMessageTests.until { !shown.isEmpty }
        #expect(shown == [id], "the opened conversation shows once its send's outcome is known")
    }

    /// A Messages page as the app's hand-off reaches it (``HomeComposerHosting``): it reads each
    /// handed file's bytes by token, chunk by chunk, as the page does (composerHandoff.ts).
    final class FakePage: NSView, HomeComposerHosting {
        let files = HomeComposerFiles()
        var asked: [(String, [String: JSONValue])] = []
        var read: [Data] = []
        var takes = true

        var composerHandoff: HomeComposerHandoff {
            HomeComposerHandoff(files: files, window: { [weak self] in self?.window }) { [weak self] op, params, _ in
                await self?.answer(op, params)
            }
        }

        private func answer(_ op: String, _ params: [String: JSONValue]) async -> JSONValue? {
            if op == "home.currentSelection" { return .object([:]) }
            asked.append((op, params))
            guard op == "home.messages.attach" else { return .object(["removed": .bool(true)]) }
            guard takes else { return .object(["attached": .bool(false), "reason": .string("noComposer")]) }
            let context = PageCallContext(page: PageDescriptor.homeMessages.id)
            for file in params["files"]?.arrayValue ?? [] {
                let answer = try? await files.call(HomeComposerFiles.prefix + "read", params: ["token": file.value(at: ["token"]) ?? .null, "offset": .number(0)],
                                                   context: context)
                read.append(answer?.value(at: ["data"])?.stringValue.flatMap { Data(base64Encoded: $0) } ?? Data())
            }
            return .object(["attached": .bool(true)])
        }
    }

    /// F1 (cmux#37736 round 10, on #37777's one hand-off): the window's Messages page takes the app's
    /// files as a drop, reading their bytes by token while it answers; the tokens go when the call
    /// ends, a missing path is refused, and a page with no composer (New Message) answers not taken,
    /// so the caller refuses.
    @Test func theAppsFilesReachTheMessagesPagesComposer() async throws {
        let folder = try HomeMessagesR6NewMessageTests.directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "quote.md")
        try Data("a quote".utf8).write(to: file)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let page = FakePage(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(page)
        let handoff = try #require(HomeComposerHandoff.shown(in: window))

        #expect(await handoff.attach([file], group: "card-1") == .accepted)
        #expect(page.read == [Data("a quote".utf8)])
        let offered = try #require(page.asked.first?.1["files"]?.arrayValue?.first)
        #expect(offered.value(at: ["name"]) == .string("quote.md"))
        #expect(offered.value(at: ["size"]) == .number(7))
        #expect(page.asked.first?.1["group"] == .string("card-1"))
        let context = PageCallContext(page: PageDescriptor.homeMessages.id)
        await #expect(throws: PageError.self, "the call ended: its token reads nothing") {
            _ = try await page.files.call(HomeComposerFiles.prefix + "read", params: ["token": offered.value(at: ["token"]) ?? .null, "offset": .number(0)],
                                          context: context)
        }

        #expect(await handoff.attach([folder.appending(path: "missing.txt")]) == .missingFile)
        page.takes = false
        #expect(await handoff.attach([file]) == .notTaken)
        await handoff.remove(group: "card-1")
        #expect(page.asked.last?.0 == "home.messages.detach")
        page.isHidden = true
        #expect(HomeComposerHandoff.shown(in: window) == nil, "a hidden page takes nothing")
    }
}
