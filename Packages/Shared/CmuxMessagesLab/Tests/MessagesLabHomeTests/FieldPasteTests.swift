import AppKit
import Testing
@testable import MessagesLabHome

/// Cmd+V reaches `paste(_:)` only when the Paste menu item validates. The
/// compose field is a plain-text NSTextView, which validates Paste only for
/// text types, so a copied screenshot (picture bytes, no text) left Cmd+V
/// disabled and the host's attachment intake never ran.
@MainActor @Suite(.serialized) struct FieldPasteTests {
    /// A private pasteboard, so the test never touches the user's clipboard.
    private func board(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        fill(pb)
        return pb
    }

    private func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func field(_ pb: NSPasteboard) -> FieldTextView {
        let tv = FieldTextView(usingTextLayoutManager: true)
        tv.isRichText = false
        tv.pasteboard = pb
        return tv
    }

    private func pasteItem() -> NSMenuItem {
        NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    }

    @Test func aScreenshotOnTheClipboardEnablesPasteWhenTheHostTakesIt() {
        let pb = board { $0.setData(png(), forType: .png) }
        defer { pb.releaseGlobally() }
        let tv = field(pb)
        var asked: [NSPasteboard] = []
        tv.acceptsPastePasteboard = { asked.append($0); return true }
        #expect(tv.validateUserInterfaceItem(pasteItem()))
        #expect(asked.count == 1 && asked.first === pb)
    }

    @Test func pasteOfAScreenshotGoesToTheHostIntake() {
        let pb = board { $0.setData(png(), forType: .png) }
        defer { pb.releaseGlobally() }
        let tv = field(pb)
        var taken = 0
        tv.onPastePasteboard = { _ in taken += 1; return true }
        tv.paste(nil)
        #expect(taken == 1)
        #expect(tv.string.isEmpty)
    }

    /// Text the host declines falls through to NSTextView's own paste (which
    /// reads the general pasteboard, so only the routing is checked here).
    @Test func textTheHostDeclinesFallsThroughToTextPaste() {
        let pb = board { $0.setString("hello", forType: .string) }
        defer { pb.releaseGlobally() }
        let tv = field(pb)
        var offered = 0, images = 0
        tv.onPastePasteboard = { _ in offered += 1; return false }
        tv.onPasteImage = { _ in images += 1 }
        tv.paste(nil)
        #expect(offered == 1)
        #expect(images == 0)
    }

    @Test func otherMenuItemsAreNotForcedOn() {
        let pb = board { $0.setData(png(), forType: .png) }
        defer { pb.releaseGlobally() }
        let tv = field(pb)
        tv.acceptsPastePasteboard = { _ in true }
        let item = NSMenuItem(title: "Paste and Match Style", action: #selector(NSTextView.pasteAsRichText(_:)), keyEquivalent: "")
        #expect(!tv.validateUserInterfaceItem(item))
    }

    // MARK: Paste and Match Style (Edit menu, Cmd+Shift+V)

    /// A field whose plain-text read is stubbed (the CI Macs' pasteboard server
    /// answers reads of a fresh private board inconsistently); `asked` collects
    /// the boards it was asked about.
    private func plainField(_ pb: NSPasteboard, text: String?, asked: @escaping (NSPasteboard) -> Void = { _ in }) -> FieldTextView {
        let tv = field(pb)
        tv.plainText = { asked($0); return text }
        return tv
    }

    private func plainItem() -> NSMenuItem {
        NSMenuItem(title: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
    }

    /// Rich text, HTML and RTF from a web page or a document: the field takes
    /// the clipboard's plain text only, at the caret, in its own typing style,
    /// and never offers the board to the attachment intake.
    @Test func pasteAndMatchStyleInsertsOnlyThePlainTextAtTheCaret() {
        let pb = board {
            $0.declareTypes([.rtf, .html, .string], owner: nil)
            $0.setString("<b><a href=\"https://example.com\">bold link</a></b>", forType: .html)
            $0.setString("bold link", forType: .string)
        }
        defer { pb.releaseGlobally() }
        var boards: [NSPasteboard] = []
        let tv = plainField(pb, text: "bold link") { boards.append($0) }
        tv.typingAttributes = [.font: NSFont.systemFont(ofSize: 13)]
        tv.string = "ab"
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        var intake = 0, images = 0
        tv.onPastePasteboard = { _ in intake += 1; return true }
        tv.onPasteImage = { _ in images += 1 }
        tv.pasteAsPlainText(nil)
        let text = tv.string, caret = tv.selectedRange()
        let attributes = tv.textStorage?.attributes(at: 1, effectiveRange: nil) ?? [:]
        let size = (attributes[.font] as? NSFont)?.pointSize
        let asked = boards.count == 1 && boards.first === pb
        #expect(text == "abold linkb")
        #expect(caret == NSRange(location: 10, length: 0))
        #expect(intake == 0 && images == 0)
        #expect(asked)
        #expect(attributes[.link] == nil)
        #expect(size == 13)
    }

    /// A selection is replaced by the plain text.
    @Test func pasteAndMatchStyleReplacesTheSelection() {
        let pb = board { $0.setString("new", forType: .string) }
        defer { pb.releaseGlobally() }
        let tv = plainField(pb, text: "new")
        tv.string = "an old word"
        tv.setSelectedRange(NSRange(location: 3, length: 3))
        tv.pasteAsPlainText(nil)
        let text = tv.string
        #expect(text == "an new word")
    }

    /// A picture alone (a copied screenshot) has no text: Paste and Match
    /// Style inserts nothing and attaches nothing, and its menu item is off.
    @Test func pasteAndMatchStyleOfAPictureDoesNothing() {
        let pb = board { $0.setData(png(), forType: .png) }
        defer { pb.releaseGlobally() }
        let tv = plainField(pb, text: nil)
        tv.string = "keep"
        var intake = 0, images = 0
        tv.acceptsPastePasteboard = { _ in true }
        tv.onPastePasteboard = { _ in intake += 1; return true }
        tv.onPasteImage = { _ in images += 1 }
        let enabled = tv.validateUserInterfaceItem(plainItem())
        tv.pasteAsPlainText(nil)
        let text = tv.string
        #expect(!enabled)
        #expect(text == "keep")
        #expect(intake == 0 && images == 0)
    }

    /// Text on the field's pasteboard enables Paste and Match Style.
    @Test func pasteAndMatchStyleIsEnabledForText() {
        let pb = board { $0.setString("hi", forType: .string) }
        defer { pb.releaseGlobally() }
        let tv = plainField(pb, text: "hi")
        let enabled = tv.validateUserInterfaceItem(plainItem())
        #expect(enabled)
    }

    // MARK: Text beside attachments, and Copy out of the box (the user, msg 12179)

    /// A paste the host's intake took that also carries words (a note's text around its pictures,
    /// the box's own copy of text and a picture): the words go in at the caret, as one edit.
    @Test func wordsBesideTakenAttachmentsPasteAtTheCaret() {
        let pb = board { $0.setString("look", forType: .string) }
        defer { pb.releaseGlobally() }
        let tv = field(pb)
        tv.string = "ab"
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        var asked = 0
        tv.onPastePasteboard = { _ in true }
        tv.pasteTextBesideAttachments = { _ in asked += 1; return "look" }
        tv.paste(nil)
        let text = tv.string, caret = tv.selectedRange()
        #expect(text == "alookb")
        #expect(caret == NSRange(location: 5, length: 0))
        #expect(asked == 1)
    }

    /// A paste the host took with no words beside it inserts nothing.
    @Test func takenAttachmentsAloneInsertNoText() {
        let pb = board { $0.setData(png(), forType: .png) }
        defer { pb.releaseGlobally() }
        let tv = field(pb)
        tv.string = "keep"
        tv.onPastePasteboard = { _ in true }
        tv.pasteTextBesideAttachments = { _ in nil }
        tv.paste(nil)
        let text = tv.string
        #expect(text == "keep")
    }

    private func picture(_ id: ID, name: String) -> MessagesLabHome.Attachment {
        MessagesLabHome.Attachment(id: id, kind: "image", fileName: name, mimeType: "image/png", byteSize: 4, asset: nil, poster: nil,
                   width: 2, height: 2, durationSeconds: nil, transfer: .done)
    }

    /// The box's text as it holds a picture between two words.
    private func textWithPicture() -> NSAttributedString {
        let s = NSMutableAttributedString(string: "look ")
        s.append(NSAttributedString(attachment: ComposeInlineAttachment(picture("h1", name: "cat.png"), scale: 2)))
        s.append(NSAttributedString(string: " here"))
        return s
    }

    /// Copy of a selection holding a picture: other apps got the text with an invisible U+FFFC
    /// in it and no picture. Now the words come without the mark, and the picture's file follows.
    @Test func copyOfAPictureInTheBoxCarriesItsFileAndCleanWords() throws {
        let file = URL(fileURLWithPath: "/tmp/open/h1/cat.png")
        let copy = ComposeSelectionCopy(file: { $0 == "h1" ? file : nil })
        let s = textWithPicture()
        let pieces = try #require(copy.pieces(s, ranges: [NSRange(location: 0, length: s.length)]))
        #expect(pieces.text == "look  here")
        #expect(pieces.files == [file])
        let items = copy.items(pieces)
        #expect(items.count == 2)
        #expect(items.first?.string(forType: .string) == "look  here")
        #expect(items.last?.string(forType: .fileURL) == file.absoluteString)
    }

    /// A selection with no picture keeps NSTextView's own Copy (nil: nothing to change).
    @Test func copyOfWordsAloneKeepsTheTextViewsCopy() {
        let copy = ComposeSelectionCopy(file: { _ in nil })
        let s = textWithPicture()
        #expect(copy.pieces(s, ranges: [NSRange(location: 0, length: 4)]) == nil)
    }

    /// A picture whose file cannot be found here still leaves its mark out of the copied words.
    @Test func copyOfAPictureWithNoFileStillDropsItsMark() throws {
        let copy = ComposeSelectionCopy(file: { _ in nil })
        let s = textWithPicture()
        let pieces = try #require(copy.pieces(s, ranges: [NSRange(location: 0, length: s.length)]))
        #expect(pieces.text == "look  here")
        #expect(pieces.files.isEmpty)
        #expect(copy.items(pieces).count == 1)
    }
}
