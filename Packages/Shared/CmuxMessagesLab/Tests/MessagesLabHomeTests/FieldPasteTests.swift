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
}
