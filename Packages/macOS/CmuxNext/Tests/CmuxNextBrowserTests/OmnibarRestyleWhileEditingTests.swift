import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Lucas 2026-11-16: "after switching densities it got smaller". The omnibar's own field editor (TextKit 2) kept its
/// typed text laid out at the previous density's size when a density change restyled it while editing. A restyle now
/// lays the typed text out again at the new font.
@MainActor @Suite(.serialized) struct OmnibarRestyleWhileEditingTests {
    @Test func aRestyleWhileEditingLaysTheTextOutAtTheNewFont() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        let chrome = BrowserChromeView(tab: page)
        chrome.frame = window.contentLayoutRect
        window.contentView = chrome
        window.makeKeyAndOrderFront(nil)
        chrome.layoutSubtreeIfNeeded()
        let field = chrome.addressBar.field
        field.font = Typography.system(size: 14, weight: TypeScale.regular)
        chrome.addressBar.focus()
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("Das", replacementRange: NSRange(location: 0, length: 0))
        // The typed text's drawn height, from a 2x bitmap of the field and its editor (what the person sees).
        func inkHeight() -> CGFloat {
            let size = field.bounds.size
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return -1 }
            rep.size = size
            field.cacheDisplay(in: field.bounds, to: rep)
            editor.cacheDisplay(in: editor.bounds, to: rep)
            var minY = Int.max, maxY = -1
            for y in 0..<rep.pixelsHigh {
                for x in 0..<min(rep.pixelsWide, 80) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= 0.25 {
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
            return maxY >= minY ? CGFloat(maxY - minY + 1) / 2 : -1
        }
        let before = inkHeight()
        field.font = Typography.system(size: 20, weight: TypeScale.regular)
        field.restyle("Das", style: .plain)
        let after = inkHeight()
        #expect(after > before + 2, "the typed text draws \(after) pt tall after the restyle, \(before) pt before")
    }

    /// The omnibar's cell keeps one field editor across editing sessions. A restyle while the omnibar is not editing (a
    /// density change from Settings) must reach that editor too, so text typed into the empty omnibar afterwards takes
    /// the new font, not the last session's.
    @Test func textTypedAfterARestyleAtRestTakesTheNewFont() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        let chrome = BrowserChromeView(tab: page)
        chrome.frame = window.contentLayoutRect
        window.contentView = chrome
        window.makeKeyAndOrderFront(nil)
        chrome.layoutSubtreeIfNeeded()
        let bar = chrome.addressBar
        let field = bar.field
        field.font = Typography.system(size: 14, weight: TypeScale.regular)
        field.restyle("", style: .plain)
        bar.focus()
        window.makeFirstResponder(nil)
        let bigger = Typography.system(size: 20, weight: TypeScale.regular)
        field.font = bigger
        field.restyle("", style: .plain)
        bar.focus()
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("Das", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        let typed = editor.textStorage.flatMap { $0.length > 0 ? $0.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil }
        #expect(abs((typed?.pointSize ?? 0) - bigger.pointSize) < 0.01, "typed text took \(typed?.pointSize ?? 0) pt, the omnibar's font is \(bigger.pointSize) pt")
    }

    /// The address field's base class re-applies its font at every density change, beside the address bar's own binding:
    /// whichever ran last won, so the omnibar's text came back at the body size after some density switches (Lucas
    /// 2026-11-16). The base binding now gives the address field the omnibar's font too, at every density.
    @Test(arguments: [DensityPreset.compact, .cozy, .spacious])
    func theFieldsOwnDensityBindingGivesTheOmnibarFont(preset: DensityPreset) {
        DensityTokens.$scoped.withValue(preset.tokens) {
            let field = AddressField(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
            #expect(abs((field.font?.pointSize ?? 0) - OmnibarStyle.font.pointSize) < 0.01,
                    "\(preset): the field's own binding set \(field.font?.pointSize ?? 0) pt, the omnibar's font is \(OmnibarStyle.font.pointSize) pt")
        }
    }
}
