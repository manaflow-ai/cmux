import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Testing

/// Leo 2026-10-20: sidebar hover states should not paint the theme's color. Every sidebar row
/// hovers in the translucent neutral fill (the text ink at a few percent), but two hovers over a
/// resting fill took the selection fill instead, which is the theme's accent: an icon tile in the
/// sidebar's items and the update card's quiet and bordered buttons. Hovered, they now take the
/// neutral fill one step stronger (midway to the pressed fill), still translucent and never the
/// accent (a hover is not a selection).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarNeutralHoverTests {
    /// A dark theme with a blue accent, so the selection fill is visibly the accent.
    private static func accentScope() throws -> ThemeScope {
        let scope = ThemeScope(level: .room)
        var input = ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))
        input.accentColor = ThemeRGB(hex: 0x3B82F6)
        scope.setOverride(try #require(ThemeSpec("Neutral Hover Accent")), input: input, animated: false)
        return scope
    }

    /// Same color, ignoring alpha.
    private static func sameInk(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let lhs = lhs.usingColorSpace(.sRGB), let rhs = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) < 0.01 && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01
    }

    /// `fill` is the neutral hover ink, stronger than the resting hover fill, under the pressed
    /// fill, translucent, and not the accent selection.
    private static func expectNeutralRaisedHover(_ fill: NSColor?, in scope: ThemeScope, _ what: String) throws {
        let fill = try #require(fill, "\(what): no fill")
        let (hover, pressed, selection) = scope.perform { (Palette.hoverFill, Palette.pressedFill, Palette.selectionFill) }
        #expect(!sameInk(selection, hover), "the test theme's selection must be its accent")
        #expect(sameInk(fill, hover), "\(what) hovers in \(fill), not the neutral hover ink")
        #expect(fill.alphaComponent > hover.alphaComponent, "\(what)'s hover is no stronger than its resting fill")
        #expect(fill.alphaComponent < pressed.alphaComponent, "\(what)'s hover is as strong as a press")
        #expect(fill.alphaComponent < 0.5, "\(what)'s hover is not translucent")
    }

    /// A tile rests on the hover fill; its hover is the next neutral step.
    @Test func aHoverOverARestingFillIsTheNeutralStepNotTheSelection() throws {
        let scope = try Self.accentScope()
        let fill = scope.perform {
            ChromeHover.fillColor(ChromeHover.State(hovering: true), rest: Palette.hoverFill)
        }
        try Self.expectNeutralRaisedHover(fill, in: scope, "a tile")
    }

    /// The same on a real tile in the sidebar's items, hovered by the pointer.
    @Test func aHoveredSidebarTileIsTheNeutralStep() throws {
        let scope = try Self.accentScope()
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 200, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scope.adopt(window)
        let row = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 44, height: 44))
        row.configure(SidebarItemInfo(title: "Home", symbol: "house"), style: .tile)
        window.contentView?.addSubview(row)
        window.orderFrontRegardless()
        defer {
            PointerHover.setDebugPointer(nil, in: window)
            window.close()
        }
        PointerHover.setDebugPointer(row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil), in: window)
        #expect(row.isHovered, "the debug pointer did not hover the tile")
        try Self.expectNeutralRaisedHover(row.fill, in: scope, "a sidebar tile")
    }

    /// The update card's quiet button rests on the hover fill; hovered, the neutral step.
    @Test func theUpdateCardsQuietButtonHoversNeutral() throws {
        let scope = try Self.accentScope()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        scope.adopt(window)
        let button = SidebarUpdateButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        button.isQuiet = true
        window.contentView?.addSubview(button)
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                       trackingNumber: 0, userData: nil))
        button.mouseEntered(with: event)
        try Self.expectNeutralRaisedHover(button.fill, in: scope, "the quiet button")
    }
}
