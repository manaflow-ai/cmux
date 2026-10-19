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
}
