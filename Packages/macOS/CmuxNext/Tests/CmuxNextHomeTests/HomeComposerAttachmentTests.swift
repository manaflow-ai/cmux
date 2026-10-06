import AppKit
@testable import CmuxHomeCore
import CmuxHomeRender
import Foundation
import Testing
@testable import CmuxNextHome

/// The Mac composer takes attachments by drop, paste and the file picker
/// (lane 16's intake, on the MessagesLab host): each becomes MessagesLab's
/// draft chip, and Send emits one message whose parts are the attachments
/// in order, then the text.
@MainActor
@Suite(.serialized) struct HomeComposerAttachmentTests {
    /// A Home view over a started store on the mock owner, its first
    /// conversation open; `recording` swaps the data side for a recorder.
    private func host(recording: Bool = true) async throws -> (NSWindow, HomeNativeTranscriptView, RecordingPreparer, HomeStore, ConversationID) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 628, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let source = MockHomeSource(options: .immediate)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("l16-home-\(UUID().uuidString)")
        let store = HomeStore(source: source, blobCacheDirectory: cache)
        store.start()
        for _ in 0..<400 where !(store.isOnline && store.me != nil) { try? await Task.sleep(for: .milliseconds(5)) }
        let inbox = try await source.inbox()
        let id = try #require(inbox.conversations.first?.id)
        await store.open(id)
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: inbox.me.id)
        let preparer = RecordingPreparer()
        if recording { view.attachmentPreparer = preparer }
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (window, view, preparer, store, id)
    }

    private func close(_ window: NSWindow, _ view: HomeNativeTranscriptView, _ store: HomeStore) {
        view.stop()
        store.stop()
        window.close()
    }

    private static func file(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data("x".utf8).write(to: url)
        return url
    }

    /// Real bytes the data side prepares: a PNG and a PDF (lane 16's fixture media).
    private static func realFiles() throws -> (png: URL, pdf: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("l16-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = dir.appendingPathComponent("photo.png")
        try HomeFixtureMedia.writePNG(width: 800, height: 600, to: png, hue: 0.1)
        let pdf = dir.appendingPathComponent("notes.pdf")
        try HomeFixtureMedia.writePDF(to: pdf)
        return (png, pdf)
    }

    private static func names(_ view: HomeNativeTranscriptView) -> [String] { view.transcript.draftAttachments.map(\.ref.name) }

    @Test func dropPasteAndPickerMakeChipsInTheOrderTheyArrived() async throws {
        let (window, view, preparer, store, _) = try await host()
        defer { close(window, view, store) }
        let photo = try Self.file("photo.png")
        #expect(view.handleDrop(FakePasteboard(fileURLs: [photo])), "a dropped file is taken")
        let paste = FakePasteboard(data: [.png: Data([0x89, 0x50, 0x4E, 0x47])])
        #expect(view.handlePaste(paste), "a pasted image is taken")
        let notes = try Self.file("notes.pdf")
        view.handlePicked([notes])
        await view.attachmentsReady()
        #expect(preparer.inputs == [.file(photo), .data(Data([0x89, 0x50, 0x4E, 0x47]), typeIdentifier: "public.png"), .file(notes)])
        #expect(Self.names(view) == ["photo.png", "pasted.png", "notes.pdf"], "the draft keeps the order they arrived in")
    }

    @Test func sendCarriesTheAttachmentsInOrderThenTheText() async throws {
        let (window, view, _, store, id) = try await host(recording: false)
        defer { close(window, view, store) }
        let (png, pdf) = try Self.realFiles()
        view.handlePicked([png, pdf])
        await view.attachmentsReady()
        let drafts = view.transcript.draftAttachments.map(\.ref.hash)
        #expect(drafts.count == 2)
        view.transcript.setDraft("Here")
        view.transcript.sendDraft()
        #expect(view.transcript.draftAttachments.isEmpty, "Send empties the draft")
        #expect(view.transcript.draftText.isEmpty)
        for _ in 0..<600 where !store.transcript(for: id).contains(where: { $0.attachmentHashes == drafts }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let sent = try #require(store.transcript(for: id).first { $0.attachmentHashes == drafts })
        #expect(sent.parts.count == 3)
        #expect(sent.parts.last == .text("Here"))
    }

    /// A Finder Copy puts the file's URL and its name as text on the
    /// pasteboard, never the bytes. Cmd-V in a Home bound to a real store
    /// must take it as an attachment (nxdog34: no chip, no bubble).
    @Test func aFinderCopiedFilePastedIntoABoundHomeBecomesAChip() async throws {
        let (window, view, _, store, _) = try await host(recording: false)
        defer { close(window, view, store) }
        let notes = try Self.realFiles().pdf
        let finderCopy = FakePasteboard(fileURLs: [notes], data: [.string: Data(notes.lastPathComponent.utf8)])
        #expect(view.handlePaste(finderCopy), "a copied file is an attachment, not its name as text")
        await view.attachmentsReady()
        #expect(Self.names(view) == [notes.lastPathComponent], "the chip shows")
        #expect(view.canAttach, "a bound Home offers the file picker too")
    }

    /// The DEBUG socket verb (`debug.home.attach`) drives the composer
    /// through the same intake as a real drop, paste or pick, so a
    /// preflight proves the user's path, not a side path.
    @Test func theDebugAttachVerbMakesTheSameChipAsADrop() async throws {
        let notes = try Self.file("notes.pdf")
        let (w1, dropped, _, s1, _) = try await host()
        defer { close(w1, dropped, s1) }
        #expect(dropped.handleDrop(FakePasteboard(fileURLs: [notes])))
        await dropped.attachmentsReady()
        for mode in HomeAttachVia.allCases {
            let (window, view, preparer, store, _) = try await host()
            defer { close(window, view, store) }
            let result = view.attachFiles(paths: [notes.path], via: mode)
            #expect(result == .accepted, "\(mode)")
            await view.attachmentsReady()
            #expect(view.transcript.draftAttachments.map(\.ref) == dropped.transcript.draftAttachments.map(\.ref), "\(mode) makes the drop's chip")
            #expect(preparer.inputs == [.file(notes)], "\(mode) goes through the preparer like a drop")
        }
        let (window, view, preparer, store, _) = try await host()
        defer { close(window, view, store) }
        #expect(view.attachFiles(paths: ["/no/such/file.pdf"], via: .drop) == .missingFile)
        view.attachmentPreparer = nil
        #expect(view.attachFiles(paths: [notes.path], via: .paste) == .notConnected, "an unconnected composer says so")
        #expect(preparer.inputs.isEmpty)
    }

    /// One type rule for paste, drop and the picker: the data side's own
    /// `HomeAttachmentPolicy.accepts` (it converts TIFF and HEIF itself), so
    /// a file is never shown as droppable and then refused for its type.
    @Test func pasteDropAndPickerUseTheDataSidesTypeRule() async throws {
        let (window, view, preparer, store, _) = try await host()
        defer { close(window, view, store) }
        let tiff = try Self.file("scan.tiff")
        let tool = try Self.file("tool.exe")
        #expect(HomeAttachmentIntake.offers(FakePasteboard(fileURLs: [tiff])), "a TIFF the data side converts can be dropped")
        #expect(!HomeAttachmentIntake.offers(FakePasteboard(fileURLs: [tool])), "a refused type is not offered while dragging")
        #expect(view.handleDrop(FakePasteboard(fileURLs: [tiff])))
        let pastedTIFF = FakePasteboard(data: [.tiff: Data([0x49, 0x49, 0x2A, 0x00])])
        #expect(view.handlePaste(pastedTIFF))
        await view.attachmentsReady()
        #expect(preparer.inputs == [.file(tiff), .data(Data([0x49, 0x49, 0x2A, 0x00]), typeIdentifier: "public.tiff")],
                "both reach the data side unconverted")
        #expect(view.notice == nil)
        let picker = Set(HomeComposerCheck.pickerTypes.map(\.identifier))
        #expect(picker == HomeAttachmentPolicy.acceptedInputTypes, "the picker offers exactly what the data side accepts")
    }

    /// A send the owner refused after logging it ("Not Delivered") says
    /// why in the composer, for example a conversation that stores no files.
    @Test func aNotDeliveredSendSaysWhy() async throws {
        let (window, view, _, store, _) = try await host()
        defer { close(window, view, store) }
        view.showNotDelivered(.invalid("attachments unsupported"))
        #expect(view.notice == "This conversation can’t receive attachments yet.")
        view.showNotDelivered(.notAuthorized)
        #expect(view.notice == "You can’t send messages in this conversation.")
    }

    /// An op that ran out of resends (a tapback, a read cursor) may not have
    /// gone through: the composer says so, through this conversation's binding.
    @Test func anUnansweredOpShowsANotice() async throws {
        let (window, view, _, store, id) = try await host()
        defer { close(window, view, store) }
        view.binding.onUnanswered(HomeIntent(op: .setReadCursor(conversation: id, seq: 1)))
        #expect(view.notice == "A change may not have gone through. Check your connection.")
        #expect(!view.noticeLabel.isHidden)
        #expect(view.noticeLabel.frame.maxY <= view.transcript.fieldTop, "above the field")
    }

    @Test func plainTextPasteStaysText() async throws {
        let (window, view, _, store, _) = try await host()
        defer { close(window, view, store) }
        let paste = FakePasteboard(data: [.string: Data("hello".utf8)])
        #expect(!view.handlePaste(paste), "text goes to the text view")
        #expect(view.transcript.draftAttachments.isEmpty)
    }

    @Test func aDraftAttachmentCanBeRemovedAndSendsAlone() async throws {
        let (window, view, _, store, id) = try await host(recording: false)
        defer { close(window, view, store) }
        let (png, pdf) = try Self.realFiles()
        view.handlePicked([png, pdf])
        await view.attachmentsReady()
        #expect(view.transcript.draftAttachments.count == 2)
        let first = try #require(view.transcript.draftAttachments.first)
        view.transcript.removeDraftAttachment(first.ref.hash)
        #expect(Self.names(view) == ["notes.pdf"])
        let alone = try #require(view.transcript.draftAttachments.first).ref.hash
        view.transcript.sendDraft()
        for _ in 0..<600 where !store.transcript(for: id).contains(where: { $0.attachmentHashes == [alone] }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let sent = try #require(store.transcript(for: id).first { $0.attachmentHashes == [alone] }, "an attachment alone sends")
        #expect(sent.parts.count == 1)
    }

    @Test func typesOutsideTheAllowListAndFilesOver100MBAreRefusedWithANotice() async throws {
        let (window, view, preparer, store, _) = try await host()
        defer { close(window, view, store) }
        let tool = try Self.file("tool.exe")
        view.handlePicked([tool])
        await view.attachmentsReady()
        #expect(view.notice == "“\(tool.lastPathComponent)” can’t be attached. You can attach photos, videos, audio, PDFs, text files and ZIP archives.")
        let big = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-big.mp4")
        #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 100_000_001)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: big) }
        #expect(view.handleDrop(FakePasteboard(fileURLs: [big])))
        await view.attachmentsReady()
        #expect(view.notice == "“\(big.lastPathComponent)” is larger than 100 MB.")
        #expect(preparer.inputs.isEmpty, "refused files are never prepared (no hashing, no upload)")
        #expect(view.transcript.draftAttachments.isEmpty)
        let field = try #require(view.primaryInput as? NSTextView)
        view.window?.makeFirstResponder(field)
        field.insertText("ok", replacementRange: NSRange(location: 0, length: 0))
        #expect(view.notice == nil, "typing clears the notice")
    }

    @Test func moreThanFifteenAttachmentsAreRefusedWithANotice() async throws {
        let (window, view, preparer, store, _) = try await host()
        defer { close(window, view, store) }
        let files = try (0..<17).map { try Self.file("n\($0).pdf") }
        view.handlePicked(files)
        await view.attachmentsReady()
        #expect(view.transcript.draftAttachments.count == 15, "a message holds 16 parts: 15 attachments and the text")
        #expect(preparer.inputs.count == 15)
        #expect(view.notice == "Too many attachments. Limit: 15.")
    }

    @Test func everyRefusalHasItsOwnNotice() async throws {
        #expect(HomeStrings.attachmentRefusal(.locationNotRemoved(name: "a.jpg"))
                == "Location data couldn’t be removed from “a.jpg”, so it was not attached.")
        #expect(HomeStrings.rejection(.notAuthorized) == "You can’t send messages in this conversation.")
        #expect(HomeStrings.rejection(.rateLimited(retryAfter: nil)) == "Too many messages. Try again in a moment.")
        #expect(HomeStrings.rejection(.invalid("unknown_attachment")) == "A message couldn’t be sent.")
        let (window, view, _, store, id) = try await host()
        defer { close(window, view, store) }
        view.binding.onRefusal(HomeIntent(op: .setReadCursor(conversation: id, seq: 1)), .notAuthorized)
        #expect(view.notice == "You can’t send messages in this conversation.", "a background refusal shows in the composer notice")
    }

    /// Each binding registers its conversation's hooks with the store: a
    /// second Home of the same store keeps the first one's notices (lane 16
    /// rule: never set `store.onRefusal` or `store.onUnanswered` directly).
    @Test func twoHomesOfOneStoreEachGetTheirOwnNotices() async throws {
        let (window, view, _, store, id) = try await host()
        defer { close(window, view, store) }
        let other = ConversationID("conv_other")
        let second = HomeNativeTranscriptView(store: store, conversation: other, me: view.me)
        defer { second.stop() }
        store.reportUnanswered(HomeIntent(op: .setReadCursor(conversation: id, seq: 1)))
        #expect(view.notice == "A change may not have gone through. Check your connection.")
        #expect(second.notice == nil)
        store.reportRefusal(HomeIntent(op: .setReadCursor(conversation: other, seq: 1)), .notAuthorized)
        #expect(second.notice == "You can’t send messages in this conversation.")
    }

    /// Settings > Home, `home.attachments.keepLocation`: the composer passes
    /// the setting as read at each attach (off strips location).
    @Test func theKeepLocationSettingReachesThePreparer() async throws {
        let (window, view, preparer, store, _) = try await host()
        defer { close(window, view, store) }
        view.handlePicked([try Self.file("a.pdf")])
        await view.attachmentsReady()
        var keep = true
        view.keepLocation = { keep }
        view.handlePicked([try Self.file("b.pdf")])
        await view.attachmentsReady()
        keep = false
        view.handleDrop(FakePasteboard(data: [.png: Data([0x89, 0x50, 0x4E, 0x47])]))
        await view.attachmentsReady()
        #expect(preparer.keptLocation == [false, true, false], "off by default, then the setting as it is at each attach")
    }

    @Test func noPreparerTakesNothing() async throws {
        let (window, view, _, store, _) = try await host()
        defer { close(window, view, store) }
        view.attachmentPreparer = nil
        let drop = FakePasteboard(fileURLs: [URL(fileURLWithPath: "/tmp/x.png")])
        #expect(!view.handleDrop(drop), "without the data side nothing is accepted")
        #expect(!view.canAttach)
    }
}

/// Records what the composer asked for and answers like `HomeStore.prepareAttachment`.
@MainActor
final class RecordingPreparer: HomeAttachmentPreparing {
    private(set) var inputs: [HomeDraftInput] = []
    /// The `keepLocation` of each call, in order.
    private(set) var keptLocation: [Bool] = []

    func prepareAttachment(fileURL: URL, keepLocation: Bool) async throws -> LocalAttachment {
        inputs.append(.file(fileURL))
        keptLocation.append(keepLocation)
        let name = String(fileURL.lastPathComponent.split(separator: "-").last ?? "")
        return LocalAttachment(ref: AttachmentRef(hash: "h-\(name)", name: name, mimeType: "application/octet-stream", byteCount: 1),
                               fileURL: fileURL)
    }

    func prepareAttachment(data: Data, typeIdentifier: String, keepLocation: Bool) async throws -> LocalAttachment {
        inputs.append(.data(data, typeIdentifier: typeIdentifier))
        keptLocation.append(keepLocation)
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
