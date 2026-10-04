import AppKit
import CmuxHomeCore
import CmuxHomeRender
import Foundation
import Testing
@testable import CmuxNextHome

/// The Mac composer takes attachments by drop, paste and the file picker;
/// each becomes a draft attachment, and Send emits one message whose parts
/// are the attachments in order, then the text.
@MainActor
@Suite struct HomeComposerAttachmentTests {
    static let me = ParticipantID("user_me")
    static let conversation = ConversationID("conv_attach")

    private func host() -> (NSWindow, HomeNativeTranscriptView, RecordingPreparer) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 628, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = HomeNativeTranscriptView(conversation: Self.conversation, me: Self.me)
        let preparer = RecordingPreparer()
        view.attachmentPreparer = preparer
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.controller.update(items: [], summary: nil, typing: [], hasOlder: false)
        return (window, view, preparer)
    }


    private static func file(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data("x".utf8).write(to: url)
        return url
    }

    @Test func dropPasteAndPickerProduceTheRightParts() async throws {
        let (window, view, preparer) = host()
        defer { window.close() }
        let photo = try Self.file("photo.png")
        let drop = FakePasteboard(fileURLs: [photo])
        #expect(view.handleDrop(drop), "a dropped file is taken")

        let paste = FakePasteboard(data: [.png: Data([0x89, 0x50, 0x4E, 0x47])])
        #expect(view.handlePaste(paste), "a pasted image is taken")

        let notes = try Self.file("notes.pdf")
        view.handlePicked([notes])
        await view.attachmentsReady()

        #expect(preparer.inputs == [.file(photo), .data(Data([0x89, 0x50, 0x4E, 0x47]), typeIdentifier: "public.png"), .file(notes)])
        let drafts = view.field.draftAttachments.map(\.ref)
        #expect(drafts.map(\.name) == ["photo.png", "pasted.png", "notes.pdf"], "the draft keeps the order they arrived in")
        #expect(!view.field.tray.isHidden)

        var sent: [HomeIntent] = []
        view.controller.onIntent = { sent.append($0) }
        view.field.text = "Here"
        view.sendDraft()
        let intent = try #require(sent.first)
        guard case .sendMessage(let id, let parts) = intent.op else { Issue.record("not a send"); return }
        #expect(id == Self.conversation)
        #expect(parts == drafts.map { MessagePart.attachment($0) } + [.text("Here")])
        #expect(view.field.draftAttachments.isEmpty, "Send empties the draft")
        #expect(view.field.text.isEmpty)
        #expect(view.field.tray.isHidden)
    }

    /// A Finder Copy puts the file's URL and its name as text on the
    /// pasteboard, never the bytes. Cmd-V in a Home bound to a real store
    /// must take it as an attachment (nxdog34: no chip, no bubble).
    @Test func aFinderCopiedFilePastedIntoABoundHomeBecomesAChip() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 628, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("l16-paste-\(UUID().uuidString)")
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: cache)
        let view = HomeNativeTranscriptView(conversation: Self.conversation, me: Self.me)
        window.contentView = view
        let binding = HomeStoreBinding(store: store, controller: view.controller)
        defer { binding.stop() }
        view.connect(binding)
        let notes = try Self.file("notes.pdf")
        let finderCopy = FakePasteboard(fileURLs: [notes], data: [.string: Data(notes.lastPathComponent.utf8)])
        #expect(view.handlePaste(finderCopy), "a copied file is an attachment, not its name as text")
        await view.attachmentsReady()
        #expect(view.field.draftAttachments.map(\.ref.name) == [notes.lastPathComponent], "the chip shows")
        #expect(!view.field.attachButton.isHidden, "a bound Home offers the file picker too")
    }

    /// The DEBUG socket verb (`debug.home.attach`) drives the composer
    /// through the same intake as a real drop, paste or pick, so a
    /// preflight proves the user's path, not a side path.
    @Test func theDebugAttachVerbMakesTheSameChipAsADrop() async throws {
        let notes = try Self.file("notes.pdf")
        let (w1, dropped, _) = host()
        defer { w1.close() }
        #expect(dropped.handleDrop(FakePasteboard(fileURLs: [notes])))
        await dropped.attachmentsReady()
        for mode in HomeAttachVia.allCases {
            let (window, view, preparer) = host()
            defer { window.close() }
            let result = view.attachFiles(paths: [notes.path], via: mode)
            #expect(result == .accepted, "\(mode)")
            await view.attachmentsReady()
            #expect(view.field.draftAttachments.map(\.ref) == dropped.field.draftAttachments.map(\.ref), "\(mode) makes the drop's chip")
            #expect(preparer.inputs == [.file(notes)], "\(mode) goes through the preparer like a drop")
        }
        let (window, view, preparer) = host()
        defer { window.close() }
        #expect(view.attachFiles(paths: ["/no/such/file.pdf"], via: .drop) == .missingFile)
        view.attachmentPreparer = nil
        #expect(view.attachFiles(paths: [notes.path], via: .paste) == .notConnected, "an unconnected composer says so")
        #expect(preparer.inputs.isEmpty)
    }

    @Test func plainTextPasteStaysText() {
        let (window, view, _) = host()
        defer { window.close() }
        let paste = FakePasteboard(data: [.string: Data("hello".utf8)])
        #expect(!view.handlePaste(paste), "text goes to the text view")
        #expect(view.field.draftAttachments.isEmpty)
    }

    @Test func aDraftAttachmentCanBeRemovedAndSendsAlone() async throws {
        let (window, view, _) = host()
        defer { window.close() }
        view.handlePicked([try Self.file("a.zip"), try Self.file("b.mov")])
        await view.attachmentsReady()
        #expect(view.field.draftAttachments.count == 2)
        let first = try #require(view.field.draftAttachments.first)
        view.field.removeDraft(first.ref.hash)
        #expect(view.field.draftAttachments.map(\.ref.name) == ["b.mov"])
        var sent: [HomeIntent] = []
        view.controller.onIntent = { sent.append($0) }
        view.sendDraft()
        guard case .sendMessage(_, let parts) = sent.first?.op else { Issue.record("an attachment alone sends"); return }
        #expect(parts.count == 1)
    }

    @Test func typesOutsideTheAllowListAndFilesOver100MBAreRefusedWithANotice() async throws {
        let (window, view, preparer) = host()
        defer { window.close() }
        let tool = try Self.file("tool.exe")
        view.handlePicked([tool])
        await view.attachmentsReady()
        #expect(view.field.notice == "“\(tool.lastPathComponent)” can’t be attached. You can attach photos, videos, audio, PDFs, text files and ZIP archives.")
        let big = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-big.mp4")
        #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 100_000_001)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: big) }
        let drop = FakePasteboard(fileURLs: [big])
        #expect(view.handleDrop(drop))
        await view.attachmentsReady()
        #expect(view.field.notice == "“\(big.lastPathComponent)” is larger than 100 MB.")
        #expect(preparer.inputs.isEmpty, "refused files are never prepared (no hashing, no upload)")
        #expect(view.field.draftAttachments.isEmpty)
        view.field.text = "ok"
        #expect(view.field.notice == nil, "typing clears the notice")
    }

    @Test func moreThanFifteenAttachmentsAreRefusedWithANotice() async throws {
        let (window, view, preparer) = host()
        defer { window.close() }
        let files = try (0..<17).map { try Self.file("n\($0).pdf") }
        view.handlePicked(files)
        await view.attachmentsReady()
        #expect(view.field.draftAttachments.count == 15, "a message holds 16 parts: 15 attachments and the text")
        #expect(preparer.inputs.count == 15)
        #expect(view.field.notice == "Too many attachments. Limit: 15.")
    }

    @Test func aClickOnAVideoBubblePlaysIt() throws {
        let (window, view, _) = host()
        defer { window.close() }
        let video = AttachmentRef(hash: "h-video", name: "clip.mov", mimeType: "video/quicktime", byteCount: 10, width: 640, height: 360)
        let chief = ParticipantID("agent_chief")
        let message = Message(id: MessageID("msg_1"), conversation: Self.conversation, seq: 1, clientMessageID: IdempotencyKey("key_1"),
                              author: chief, parts: [.attachment(video)], createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        view.controller.update(items: CmuxHomeCore.TranscriptWindow(messages: [message]).items(pending: [], me: Self.me),
                               summary: nil, typing: [], hasOlder: false)
        view.layoutSubtreeIfNeeded()
        let item = IdempotencyKey("key_1")
        let frame = try #require(view.controller.contentFrame(for: item))
        let point = CGPoint(x: 60, y: frame.midY - view.controller.scrollGeometry.offset)
        #expect(view.rowHost.acceptsFirstMouse(for: Self.mouse(.leftMouseDown, at: point, in: view.rowHost)),
                "a click on a video plays it even in an inactive window")
        view.rowHost.mouseDown(with: try #require(Self.mouse(.leftMouseDown, at: point, in: view.rowHost)))
        view.rowHost.mouseUp(with: try #require(Self.mouse(.leftMouseUp, at: point, in: view.rowHost)))
        #expect(view.controller.videoState(for: item, partIndex: 0) == .loading, "the click starts playback (fetching the URL)")
    }

    private static func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    @Test func everyRefusalHasItsOwnNotice() {
        #expect(HomeStrings.attachmentRefusal(.locationNotRemoved(name: "a.jpg"))
                == "Location data couldn’t be removed from “a.jpg”, so it was not attached.")
        #expect(HomeStrings.rejection(.notAuthorized) == "You can’t send messages in this conversation.")
        #expect(HomeStrings.rejection(.rateLimited(retryAfter: nil)) == "Too many messages. Try again in a moment.")
        #expect(HomeStrings.rejection(.invalid("unknown_attachment")) == "A message couldn’t be sent.")
        let (window, view, _) = host()
        defer { window.close() }
        view.showRefusal(.notAuthorized)
        #expect(view.field.notice == "You can’t send messages in this conversation.", "a background refusal shows in the composer notice")
    }

    @Test func theMenuOffersCancelUploadOnlyWhenTheSendCanBeCancelled() throws {
        let (window, view, _) = host()
        defer { window.close() }
        let photo = AttachmentRef(hash: "h-photo", name: "p.png", mimeType: "image/png", byteCount: 10, width: 400, height: 300)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let uploading = TranscriptItem(key: IdempotencyKey("up"), seq: nil, author: Self.me, parts: [.attachment(photo)],
                                       createdAt: start, delivery: .sending, attachmentProgress: [photo.hash: 0.4])
        let waiting = TranscriptItem(key: IdempotencyKey("wait"), seq: nil, author: Self.me, parts: [.attachment(photo)],
                                     createdAt: start.addingTimeInterval(400), delivery: .sending)
        view.controller.update(items: [uploading, waiting], summary: nil, typing: [], hasOlder: false)
        view.layoutSubtreeIfNeeded()
        var cancelled: [IdempotencyKey] = []
        view.onCancelSend = { cancelled.append($0); return true }
        func menu(_ key: String) throws -> NSMenu? {
            let frame = try #require(view.controller.contentFrame(for: IdempotencyKey(key)))
            return view.rowHost.menu(at: CGPoint(x: frame.width - 60, y: frame.midY - view.controller.scrollGeometry.offset))
        }
        let up = try #require(try menu("up"))
        let cancel = try #require(up.items.first { $0.title == "Cancel Upload" }, "an uploading attachment offers Cancel Upload")
        _ = view.rowHost.perform(try #require(cancel.action), with: cancel)
        #expect(cancelled == [IdempotencyKey("up")])
        let wait = try menu("wait")
        #expect(wait?.items.contains { $0.title == "Cancel Upload" } != true, "a sent, unanswered message offers no Cancel")
    }

    @Test func noPreparerTakesNothing() {
        let (window, view, _) = host()
        defer { window.close() }
        view.attachmentPreparer = nil
        let drop = FakePasteboard(fileURLs: [URL(fileURLWithPath: "/tmp/x.png")])
        #expect(!view.handleDrop(drop), "without the data side nothing is accepted")
        #expect(view.field.attachButton.isHidden)
    }
}

/// Records what the composer asked for and answers like `HomeStore.prepareAttachment`.
@MainActor
final class RecordingPreparer: HomeAttachmentPreparing {
    private(set) var inputs: [HomeDraftInput] = []

    func prepareAttachment(fileURL: URL, keepLocation: Bool) async throws -> LocalAttachment {
        inputs.append(.file(fileURL))
        let name = String(fileURL.lastPathComponent.split(separator: "-").last ?? "")
        return LocalAttachment(ref: AttachmentRef(hash: "h-\(name)", name: name, mimeType: "application/octet-stream", byteCount: 1),
                               fileURL: fileURL)
    }

    func prepareAttachment(data: Data, typeIdentifier: String, keepLocation: Bool) async throws -> LocalAttachment {
        inputs.append(.data(data, typeIdentifier: typeIdentifier))
        return LocalAttachment(ref: AttachmentRef(hash: "h-pasted", name: "pasted.png", mimeType: "image/png", byteCount: data.count,
                                                  width: 2, height: 2),
                               fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("pasted.png"))
    }
}

/// A pasteboard value: the composer reads it like `NSPasteboard`, with no
/// pasteboard server (ci-step minis run tests without one).
struct FakePasteboard: HomePasteboardContents {
    var fileURLs: [URL] = []
    var data: [NSPasteboard.PasteboardType: Data] = [:]

    func hasType(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains { $0 == .fileURL ? !fileURLs.isEmpty : data[$0] != nil }
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? { data[type] }
}
