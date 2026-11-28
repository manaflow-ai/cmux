import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-20: "tooltips everywhere needs to be redesigned to be better and consistent",
/// on the composer's "Select effort ⌃⇧M": one line of regular text, then the shortcut's keys as plain
/// glyphs, no plate (Leo 2026-11-22: "a bullshit looking fucking command icon"). Every native tooltip draws ``TooltipContentView`` on the one panel, a page's
/// tooltip past its window's edge included (before: a menu row, 13 pt, its keys as plain text), in
/// one height whether it has keys or not, with corners that nest, and it shows and goes in one frame.
@MainActor @Suite(.closesItsWindows, .serialized) struct TooltipDesignTests {
    static var scale: CGFloat { Typography.userScale }

    @Test func aShortcutIsPlainGlyphsAfterTheText() throws {
        let content = TooltipContentView()
        content.set(text: "Select effort", shortcut: "⌃⇧M")
        let size = content.fittingSurfaceSize()
        content.frame = NSRect(origin: .zero, size: size)
        content.layoutSubtreeIfNeeded()
        let keycap = try #require(content.keycap, "the shortcut has no keycap")
        #expect(keycap.label.stringValue == "⌃⇧M")
        #expect(keycap.style == .plainGlyph, "the tooltip's keys sit on a plate")
        #expect(!keycap.style.hasPlate)
        // The keys end at the inline padding.
        let inset = TooltipMetrics.paddingInline * Self.scale
        #expect(abs(keycap.frame.maxX - (size.width - inset)) < 0.5, "keycap at \(keycap.frame), surface \(size)")
        // After the text, with the gap between them, and centred on its line. The label's frame holds 2 pt of line
        // padding each side of its glyphs; its alignment rect is the glyphs' box, which starts at the inline padding.
        let glyphs = content.text.alignmentRect(forFrame: content.text.frame)
        #expect(abs(glyphs.minX - TooltipMetrics.paddingInline * Self.scale) < 0.5, "text starts at \(glyphs.minX)")
        #expect(glyphs.maxX + TooltipMetrics.keycapGap * Self.scale <= keycap.frame.minX + 0.5, "text \(glyphs) keycap \(keycap.frame)")
        #expect(abs(glyphs.midY - keycap.frame.midY) <= 0.5, "text \(glyphs) keycap \(keycap.frame)")
        // No plate: no fill, no corner.
        #expect(keycap.layer?.cornerRadius ?? 0 == 0)
        // Regular text at the detail size, never the old bold caption.
        let font = try #require(content.text.font)
        #expect(font.pointSize == TooltipMetrics.fontSize * Self.scale)
        #expect(!font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func aTooltipWithKeysIsAsTallAsOneWithout() {
        let plain = TooltipContentView()
        plain.set(text: "Back", shortcut: nil)
        let keyed = TooltipContentView()
        keyed.set(text: "Back", shortcut: "⌘[")
        #expect(plain.keycap == nil)
        let expected = ceil((TooltipMetrics.lineHeight + TooltipMetrics.paddingBlock * 2) * Self.scale)
        #expect(plain.fittingSurfaceSize().height == expected)
        #expect(keyed.fittingSurfaceSize().height == expected)
        // An empty or blank shortcut draws no keycap.
        keyed.set(text: "Back", shortcut: "  ")
        #expect(keyed.keycap == nil)
    }

    /// a1315 (UI simplification lead; Lawrence: "drastically simplify all parts of the UI"): a tooltip is the
    /// control's name and its shortcut, on one line. Text past the maximum width ends in an ellipsis, and a second
    /// line never shows.
    @Test func aTooltipIsOneLineAtMostTheMaximumWidth() {
        let oneLine = ceil((TooltipMetrics.lineHeight + TooltipMetrics.paddingBlock * 2) * Self.scale)
        let long = TooltipContentView()
        long.set(text: String(repeating: "a long tooltip that would wrap ", count: 8), shortcut: "⌘K")
        let size = long.fittingSurfaceSize()
        #expect(size.height == oneLine, "a long tooltip took \(size.height) pt, more than one line")
        #expect(size.width <= TooltipMetrics.maxWidth * Self.scale + 0.5)
        let twoLines = TooltipContentView()
        twoLines.set(text: "Reload\nRun the script again from its saved files", shortcut: nil)
        #expect(twoLines.text.stringValue == "Reload", "the second line showed")
        #expect(twoLines.fittingSurfaceSize().height == oneLine)
    }

    /// David Beyer, 2026-11-20: tooltips "look strangely wide". A tooltip is as wide as its text.
    @Test func aTooltipIsAsWideAsItsText() {
        let scale = Self.scale
        let pad = TooltipMetrics.paddingInline * scale
        let short = TooltipContentView()
        short.set(text: "Back", shortcut: nil)
        let label = ("Back" as NSString).size(withAttributes: [.font: TooltipContentView.font]).width
        #expect(short.fittingSurfaceSize().width <= ceil(label) + 2 * pad + 8 * scale, "a one-word tooltip is wider than its word")
    }

    @Test func thePanelHasTheTooltipCornerWhateverThePaneCorners() {
        let panel = TooltipPanel()
        defer { panel.close() }
        panel.show(text: "New Tab", shortcut: "⌘T", scope: ThemeScope(level: .room), appearance: NSAppearance(named: .darkAqua)!)
        #expect(panel.glass.cornerRadius == TooltipMetrics.radius * Self.scale)
        #expect(panel.content.frame.size == panel.surfaceSize)
    }

    @Test func aViewsTooltipShowsAndGoesInOneFrame() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 300, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = NSButton(frame: NSRect(x: 20, y: 40, width: 24, height: 24))
        window.contentView?.addSubview(button)
        window.orderFrontRegardless()
        button.themedToolTip = "Reload"
        button.themedToolTipShortcut = "⌘R"
        let presenter = ThemedTooltipTests.instantPresenter()
        defer { ThemedTooltipTests.putAway(presenter) }
        let tracker = try #require(TooltipTracker.whole(of: button))
        presenter.dismiss()
        presenter.enter(tracker)
        let panel = presenter.panel
        #expect(panel.isVisible)
        #expect(panel.surface.layer?.animationKeys()?.isEmpty ?? true, "the tooltip animated in")
        #expect(panel.surface.layer?.opacity == 1)
        presenter.exit(tracker)
        #expect(!panel.isVisible, "the tooltip lingered after the pointer left")
        window.closeAfterTest()
    }

    @Test func aPageTooltipPastItsWindowIsTheSameTooltip() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 320, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        window.contentView?.addSubview(page)
        window.orderFrontRegardless()
        let host = WebPopupHost(webView: page, zoom: { 1 }, send: { _ in })
        let model = try #require(WebPopupHost.Model([
            "items": [["id": "0", "label": "Select effort", "shortcut": "⌃⇧M"]], "kind": "tooltip",
            "anchor": ["left": 40, "top": 170, "right": 160, "bottom": 196], "width": 160,
        ]))
        let presenter = TooltipPresenter.shared
        defer {
            host.hide()
            presenter.panel.close()
            window.closeAfterTest()
        }
        let reply = host.show(model)
        #expect(reply["shown"] as? Bool == true)
        #expect(presenter.external?.text == "Select effort")
        #expect(presenter.external?.shortcut == "⌃⇧M")
        #expect(presenter.panel.isVisible)
        #expect(presenter.panel.content.keycap?.label.stringValue == "⌃⇧M")
        // No menu panel draws it.
        #expect(!NSApp.windows.contains { $0 is WebPopupPanel && $0.isVisible && $0.parent === window })
        // Below its anchor (the page's bottom edge), as a view's tooltip.
        let frame = try #require(host.shownFrame)
        let anchorBottomOnScreen = window.frame.minY + (200 - 196)
        #expect(frame.maxY <= anchorBottomOnScreen + 0.5, "frame \(frame), anchor bottom \(anchorBottomOnScreen)")
        host.hide()
        #expect(presenter.external == nil)
        #expect(!presenter.panel.isVisible)
    }

    @Test func belowByDefaultAboveWhenAskedOrWhenThereIsNoRoom() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: 100, height: 24)
        let gap = TooltipPresenter.gap
        let middle = NSRect(x: 400, y: 400, width: 40, height: 24)
        #expect(TooltipPresenter.origin(for: size, below: middle, on: screen).y == (middle.minY - gap - size.height).rounded())
        #expect(TooltipPresenter.origin(for: size, below: middle, on: screen, preferAbove: true).y == (middle.maxY + gap).rounded())
        let bottom = NSRect(x: 400, y: 4, width: 40, height: 24)
        #expect(TooltipPresenter.origin(for: size, below: bottom, on: screen).y == (bottom.maxY + gap).rounded())
        let top = NSRect(x: 400, y: 790, width: 40, height: 10)
        #expect(TooltipPresenter.origin(for: size, below: top, on: screen, preferAbove: true).y == (top.minY - gap - size.height).rounded())
        // Shifted to stay on screen at the edges.
        let left = NSRect(x: 0, y: 400, width: 10, height: 24)
        #expect(TooltipPresenter.origin(for: size, below: left, on: screen).x == TooltipPresenter.edge)
    }
}
