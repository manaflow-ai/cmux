import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
import ImageIO
@testable import MessagesLabHome
import Testing
import UniformTypeIdentifiers

/// A picture pasted, dropped or picked in the Home message box sits in the
/// text at the caret, as in Messages and Notes, with a remove button, and goes
/// out with the message (Lawrence 2026-10-19: "I still don't have inline
/// images inside the typing area for the iMessage thing"). Drives the real
/// `HomeNativeTranscriptView` over a `HomeStore` on the mock owner, through
/// the same intake as Cmd+V, a drop and the + picker, in an offscreen window
/// that is never ordered front.
@MainActor @Suite(.serialized) struct HomeComposerInlineImageTests {
    /// Pasteboard contents as a value (a ci-step mini has no pasteboard server).
    struct Board: HomePasteboardContents {
        var fileURLs: [URL] = []
        var items: [NSPasteboard.PasteboardType: Data] = [:]
        func hasType(_ types: [NSPasteboard.PasteboardType]) -> Bool {
            types.contains { items[$0] != nil || ($0 == .fileURL && !fileURLs.isEmpty) }
        }
        func data(forType type: NSPasteboard.PasteboardType) -> Data? { items[type] }
        func string(forType type: NSPasteboard.PasteboardType) -> String? { items[type].flatMap { String(data: $0, encoding: .utf8) } }
    }

    struct Home {
        let window: NSWindow
        let store: HomeStore
        let view: HomeNativeTranscriptView
        let blobs: URL
        var controller: ChatController { view.transcript.controller }
        var compose: ComposeView { controller.demo!.compose }
        var field: FieldTextView { compose.textView.view }
        /// The attachments the field's text shows, in order, with their character offsets.
        var inline: [(offset: Int, attachment: ComposeInlineAttachment)] {
            guard let s = field.textStorage else { return [] }
            var out: [(Int, ComposeInlineAttachment)] = []
            s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, r, _ in
                if let a = v as? ComposeInlineAttachment { out.append((r.location, a)) }
            }
            return out
        }
        func close() {
            view.stop()
            store.stop()
            try? FileManager.default.removeItem(at: blobs)
        }
    }

    private func home() async throws -> Home {
        let source = MockHomeSource(options: .immediate)
        let blobs = FileManager.default.temporaryDirectory.appendingPathComponent("home-inline-\(UUID().uuidString)", isDirectory: true)
        let store = HomeStore(source: source, blobCacheDirectory: blobs)
        store.start()
        let inbox = try await source.inbox()
        let chief = await source.chief.id
        let id = try #require((inbox.conversations.first { $0.participants.contains { $0.id == chief } } ?? inbox.conversations.first)?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: inbox.me.id)
        view.frame = window.contentView!.bounds
        window.contentView!.addSubview(view)
        await view.binding.opened()
        view.layoutSubtreeIfNeeded()
        return Home(window: window, store: store, view: view, blobs: blobs)
    }

    /// A 600 x 400 px opaque PNG.
    private static func png() throws -> Data {
        let w = 600, h = 400
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private static func pngFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inline-\(UUID().uuidString).png")
        try png().write(to: url)
        return url
    }

    enum Path: String, CaseIterable { case pastePicture, pasteFile, drop, pick }

    private func attach(_ path: Path, to view: HomeNativeTranscriptView) async throws {
        switch path {
        case .pastePicture: #expect(view.handlePaste(Board(items: [.png: try Self.png()])))
        case .pasteFile: #expect(view.handlePaste(Board(fileURLs: [try Self.pngFile()])))
        case .drop: #expect(view.handleDrop(Board(fileURLs: [try Self.pngFile()])))
        case .pick: view.handlePicked([try Self.pngFile()])
        }
        await view.attachmentsReady()
        view.layoutSubtreeIfNeeded()
    }

    /// Types TEXT in the field and puts the caret at CARET.
    private func type(_ text: String, caret: Int, in h: Home) {
        #expect(h.window.makeFirstResponder(h.field))
        h.field.insertText(text, replacementRange: h.field.selectedRange())
        h.field.setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// Every entry point puts one image thumbnail in the field's text, not in a row above it.
    @Test(arguments: Path.allCases)
    func aPictureSitsInTheText(_ path: Path) async throws {
        let h = try await home()
        defer { h.close() }
        try await attach(path, to: h.view)
        #expect(h.view.transcript.draftAttachments.count == 1, "the draft holds the picture")
        let inline = h.inline
        #expect(inline.count == 1, "the field's text holds the picture")
        let a = try #require(inline.first).attachment
        #expect(a.isImage, "an image thumbnail, not a file pill")
        #expect(a.bounds.height <= ComposeAttachmentStrip.imageMaxHeight + 0.5)
        #expect(abs(a.bounds.width / a.bounds.height - 1.5) < 0.05, "the thumbnail keeps the picture's aspect")
        a.loadThumbnailNow(scale: 2)
        #expect(a.thumbnail != nil, "the thumbnail decodes")
        #expect(h.compose.strip.tiles.isEmpty, "no thumbnail row above the text")
        #expect(h.compose.fieldRect.height >= a.bounds.height, "the field is as tall as the thumbnail's line")
    }

    /// A paste in the middle of the text goes in at the caret; the text around it stays, and the caret follows it.
    @Test func aPictureGoesInAtTheCaret() async throws {
        let h = try await home()
        defer { h.close() }
        type("hello world", caret: 5, in: h)
        try await attach(.pastePicture, to: h.view)
        #expect(h.field.string == "hello\u{FFFC} world")
        #expect(h.inline.map(\.offset) == [5])
        #expect(h.field.selectedRange() == NSRange(location: 6, length: 0))
        #expect(h.view.transcript.draftText == "hello\u{FFFC} world")
    }

    /// The thumbnail's remove button takes the picture out of the text and the draft; the text stays.
    @Test func theRemoveButtonTakesThePictureOut() async throws {
        let h = try await home()
        defer { h.close() }
        type("hi", caret: 2, in: h)
        try await attach(.pastePicture, to: h.view)
        let a = try #require(h.inline.first).attachment
        let button = a.makeView()
        button.removeClicked()
        #expect(h.inline.isEmpty)
        #expect(h.view.transcript.draftAttachments.isEmpty)
        #expect(h.field.string == "hi")
        #expect(h.view.transcript.draftText == "hi")
    }

    /// Delete after the thumbnail removes it, as any character.
    @Test func deleteRemovesThePicture() async throws {
        let h = try await home()
        defer { h.close() }
        type("hi", caret: 2, in: h)
        try await attach(.pastePicture, to: h.view)
        #expect(h.field.selectedRange() == NSRange(location: 3, length: 0))
        h.field.deleteBackward(nil)
        #expect(h.inline.isEmpty)
        #expect(h.view.transcript.draftAttachments.isEmpty)
        #expect(h.view.transcript.draftText == "hi")
    }

    /// Send: the picture goes out in the message, the text without the picture's mark.
    @Test func thePictureIsSentWithTheMessage() async throws {
        let h = try await home()
        defer { h.close() }
        type("look", caret: 4, in: h)
        try await attach(.pastePicture, to: h.view)
        #expect(h.view.sendDraft() == nil)
        #expect(h.view.transcript.draftAttachments.isEmpty)
        #expect(h.inline.isEmpty)
        let sent = try #require(h.controller.store?.state.conversation.messages.last)
        var attachments = 0
        var texts: [String] = []
        for part in sent.parts {
            switch part {
            case .attachment: attachments += 1
            case .text(let t, _): texts.append(t)
            default: break
            }
        }
        #expect(attachments == 1)
        #expect(texts.joined().contains("look"))
        #expect(!texts.joined().contains("\u{FFFC}"))
    }
}
