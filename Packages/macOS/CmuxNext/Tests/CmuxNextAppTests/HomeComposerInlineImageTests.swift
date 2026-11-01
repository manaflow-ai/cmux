import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
import CmuxNextTestSupport
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
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeComposerInlineImageTests {
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

    /// A 600 x 400 px opaque PNG, blue unless RED is given.
    private static func png(red: CGFloat = 0.2) throws -> Data {
        let w = 600, h = 400
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: red, green: 0.5, blue: 0.9, alpha: 1))
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
        #expect(a.pictureSize.height <= ComposeInlineAttachment.pictureMaxHeight + 0.5)
        #expect(abs(a.pictureSize.width / a.pictureSize.height - 1.5) < 0.05, "the thumbnail keeps the picture's aspect")
        a.loadThumbnailNow(scale: 2)
        #expect(a.thumbnail != nil, "the thumbnail decodes")
        #expect(h.compose.strip.tiles.isEmpty, "no thumbnail row above the text")
        #expect(h.compose.fieldRect.height >= a.pictureSize.height + Fixture.lineHeight, "the field holds the picture and a text line under it")
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

    /// The field draws the pasted picture, not AppKit's blank document page (Austin 2026-10-20: a
    /// screenshot pasted in the Chief's box showed as a white page with a folded corner). Renders
    /// the field as the window would and looks for the picture's blue where the attachment sits.
    @Test func theFieldDrawsThePastedPicture() async throws {
        let h = try await home()
        defer { h.close() }
        try await attach(.pastePicture, to: h.view)
        let a = try #require(h.inline.first).attachment
        a.loadThumbnailNow(scale: 2)
        let field = h.field
        field.layoutSubtreeIfNeeded()
        field.display()
        let views = field.subviews.map { String(describing: Swift.type(of: $0)) }
        let textKit2 = field.textLayoutManager != nil
        let rep = try #require(field.bitmapImageRepForCachingDisplay(in: field.bounds))
        field.cacheDisplay(in: field.bounds, to: rep)
        var blue = 0, white = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
                // The picture's blue after color management (sRGB 0.2, 0.5, 0.9 draws as about 0.3, 0.7, 0.9).
                if b > 0.8, r < 0.45, g > 0.4, g < 0.8 { blue += 1 }
                if r > 0.95, g > 0.95, b > 0.95 { white += 1 }
            }
        }
        let seen = "blue \(blue), white \(white), TextKit 2 \(textKit2), subviews \(views)"
        #expect(blue > 200, "the picture is drawn in the field (\(seen))")
        #expect(white < 50, "no blank white page where the picture goes (\(seen))")
    }
    /// The thumbnail decoded in the background (as after a real paste, no `loadThumbnailNow`)
    /// reaches the field: the picture is drawn once it arrives, not the placeholder for good.
    @Test func theDecodedThumbnailReachesTheField() async throws {
        let h = try await home()
        defer { h.close() }
        try await attach(.pastePicture, to: h.view)
        let a = try #require(h.inline.first).attachment
        h.field.display()
        for _ in 0..<100 where a.thumbnail == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(a.thumbnail != nil, "the thumbnail decodes in the background")
        h.field.layoutSubtreeIfNeeded()
        h.field.display()
        let rep = try #require(h.field.bitmapImageRepForCachingDisplay(in: h.field.bounds))
        h.field.cacheDisplay(in: h.field.bounds, to: rep)
        var blue = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                if c.blueComponent > 0.8, c.redComponent < 0.45, c.greenComponent > 0.4, c.greenComponent < 0.8 { blue += 1 }
            }
        }
        #expect(blue > 200, "the picture is drawn after its thumbnail arrives (blue \(blue))")
    }

    /// Typing hides the hover remove button: the edit may have moved the picture under it.
    @Test func typingHidesTheRemoveButton() async throws {
        let h = try await home()
        defer { h.close() }
        try await attach(.pastePicture, to: h.view)
        h.field.layoutSubtreeIfNeeded()
        let hover = h.compose.inlineHover
        let picture = try #require(hover.attachmentRects().first)
        hover.pointerMoved(to: CGPoint(x: picture.rect.midX, y: picture.rect.midY))
        #expect(!hover.button.isHidden)
        type("a", caret: 0, in: h)
        #expect(hover.button.isHidden, "an edit hides the button")
    }

    /// As in Messages, a picture is a block: the caret right after a paste, and the text typed
    /// then, start the line under the picture at its left (Austin 2026-10-20, with Messages'
    /// capture: the text sat beside the picture).
    @Test func textAfterAPictureStartsTheLineUnderIt() async throws {
        let h = try await home()
        defer { h.close() }
        try await attach(.pastePicture, to: h.view)
        h.field.layoutSubtreeIfNeeded()
        let picture = try #require(h.compose.inlineHover.attachmentRects().first).rect
        #expect(picture.width < 245 && picture.height <= ComposeInlineAttachment.pictureMaxHeight + 0.5, "the picture's own size (\(picture))")
        let afterPaste = try #require(h.field.caretRects(at: [1]).fresh.first ?? nil)
        #expect(afterPaste.minX < 4, "the caret is at the left (\(afterPaste))")
        #expect(afterPaste.minY >= picture.maxY - 1, "under the picture (\(afterPaste), picture \(picture))")
        h.field.insertText("hi", replacementRange: h.field.selectedRange())
        h.view.layoutSubtreeIfNeeded()
        let firstLetter = try #require(h.field.caretRects(at: [1]).fresh.first ?? nil)
        #expect(firstLetter.minX < 4 && firstLetter.minY >= picture.maxY - 1, "the text starts under the picture (\(firstLetter))")
        #expect(h.view.transcript.draftText == "\u{FFFC}hi", "the draft holds no extra line break")
    }

    /// Text before a picture stays on its line above the picture.
    @Test func textBeforeAPictureStaysAboveIt() async throws {
        let h = try await home()
        defer { h.close() }
        type("hello", caret: 5, in: h)
        try await attach(.pastePicture, to: h.view)
        h.field.layoutSubtreeIfNeeded()
        let picture = try #require(h.compose.inlineHover.attachmentRects().first).rect
        let text = try #require(h.field.caretRects(at: [0]).fresh.first ?? nil)
        #expect(picture.minX < 4, "the picture starts its own line (\(picture))")
        #expect(picture.minY >= text.maxY - 4, "under the text line (\(picture), text \(text))")
        #expect(h.compose.fieldRect.height >= picture.height + 2 * Fixture.lineHeight, "the field holds the text, the picture and the caret's line")
    }

    /// Just before a picture that follows text, the caret ends the text's line above the picture,
    /// where a typed character goes (not over the picture's corner).
    @Test func theCaretBeforeAPictureEndsTheTextAbove() async throws {
        let h = try await home()
        defer { h.close() }
        type("hello", caret: 5, in: h)
        try await attach(.pastePicture, to: h.view)
        h.field.layoutSubtreeIfNeeded()
        let picture = try #require(h.compose.inlineHover.attachmentRects().first).rect
        let caret = try #require(h.field.caretRects(at: [5]).fresh.first ?? nil)
        #expect(caret.maxY <= picture.minY + 4, "on the text line above (\(caret), picture \(picture))")
        #expect(caret.minX > 10, "after the text (\(caret))")
    }

    /// The field measures each picture as its own line, as it lays them out: no blank line between
    /// two pictures, and the caret's line after a picture that ends with a line break.
    @Test func theFieldMeasuresPicturesAsTheirOwnLines() async throws {
        let h = try await home()
        defer { h.close() }
        #expect(h.view.handlePaste(Board(items: [.png: try Self.png()])))
        await h.view.attachmentsReady()
        #expect(h.view.handlePaste(Board(items: [.png: try Self.png(red: 0.8)])))
        await h.view.attachmentsReady()
        let two = try #require(h.field.textStorage)
        #expect(ComposeInlineText.blockLines(two).string == "\u{FFFC}\n\u{FFFC}\n ")
        let pictures = try #require(h.compose.inlineHover.attachmentRects().map(\.rect) as [CGRect]?)
        #expect(pictures.count == 2)
        if pictures.count == 2 { #expect(pictures[1].minY - pictures[0].maxY < Fixture.lineHeight, "no blank line between them (\(pictures))") }
        h.field.insertText("\n", replacementRange: h.field.selectedRange())
        let trailing = try #require(h.field.textStorage)
        #expect(ComposeInlineText.blockLines(trailing).string.hasSuffix("\u{FFFC}\n "), "the caret's line after the break is measured")
    }

    /// Hovering a picture in the field shows a remove button at its top right; the button takes
    /// the picture out (Austin 2026-10-20: hovering a pasted picture showed no remove button).
    @Test func hoveringAPictureShowsItsRemoveButton() async throws {
        let h = try await home()
        defer { h.close() }
        type("hi", caret: 2, in: h)
        try await attach(.pastePicture, to: h.view)
        h.field.layoutSubtreeIfNeeded()
        let hover = h.compose.inlineHover
        let picture = try #require(hover.attachmentRects().first)
        #expect(picture.rect.width > 20 && picture.rect.height > 20, "the picture's box in the field (\(picture.rect))")
        hover.pointerMoved(to: CGPoint(x: picture.rect.midX, y: picture.rect.midY))
        #expect(!hover.button.isHidden, "the remove button shows over the hovered picture")
        #expect(hover.button.superview === h.field)
        #expect(picture.rect.contains(CGPoint(x: hover.button.frame.midX, y: hover.button.frame.midY)), "on the picture (\(hover.button.frame))")
        hover.pointerMoved(to: CGPoint(x: picture.rect.maxX + 40, y: picture.rect.midY))
        #expect(hover.button.isHidden, "and hides off it")
        hover.pointerMoved(to: CGPoint(x: picture.rect.midX, y: picture.rect.midY))
        #expect(hover.button.accessibilityPerformPress())
        #expect(h.inline.isEmpty, "the button takes the picture out of the text")
        #expect(h.view.transcript.draftAttachments.isEmpty, "and out of the draft")
        #expect(h.field.string == "hi")
    }

    /// Two different pictures pasted one after the other both sit in the text (Austin 2026-10-20:
    /// "I can't paste more than 1 image").
    @Test func twoPastedPicturesBothSitInTheText() async throws {
        let h = try await home()
        defer { h.close() }
        #expect(h.view.handlePaste(Board(items: [.png: try Self.png()])))
        await h.view.attachmentsReady()
        #expect(h.view.handlePaste(Board(items: [.png: try Self.png(red: 0.8)])))
        await h.view.attachmentsReady()
        h.view.layoutSubtreeIfNeeded()
        #expect(h.view.transcript.draftAttachments.count == 2, "the draft holds both pictures")
        #expect(h.inline.count == 2, "the field's text holds both pictures")
    }

    /// After a picture the caret sits on the text's line at the bottom of the picture's tall line,
    /// not halfway up the picture (Austin 2026-10-20: the caret floated above the text).
    @Test func theCaretSitsOnTheTextBesideAPicture() async throws {
        let h = try await home()
        defer { h.close() }
        try await attach(.pastePicture, to: h.view)
        h.field.insertText("hi", replacementRange: h.field.selectedRange())
        h.view.layoutSubtreeIfNeeded()
        let end = (h.field.string as NSString).length
        let caret = try #require(h.field.caretRects(at: [end]).fresh.first ?? nil)
        let tlm = try #require(h.field.textLayoutManager)
        var line = CGRect.zero
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
            line = f.layoutFragmentFrame
            return false
        }
        let bottom = line.maxY + h.field.textContainerOrigin.y
        #expect(line.height > Fixture.lineHeight + 4, "the picture makes the line taller (\(line))")
        #expect(caret.maxY > bottom - Fixture.lineHeight - 2, "the caret is on the bottom text line (caret \(caret), line \(line))")
    }
}
