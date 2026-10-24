import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// cx-ujp: a cmux dialog in a light theme drew low-contrast body lines. Its labels took their
/// ink once, while the dialog was built outside any window, so a dialog shown in a light
/// window (or one whose theme turned light while it showed) kept another theme's text over the
/// light surface. The labels must re-read their ink in the scope they draw in, in an inactive
/// (never key) window too, and the surface must stay a light card, not a grey slab. These
/// check the solid card a dialog draws under Reduce Transparency; on glass the tint carries it.
@MainActor @Suite(.serialized) struct CmuxDialogLightContrastTests {
    private static let light = ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1D1D1F))
    private static let dark = ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xE6E6E6))

    /// Pins the solid popup surface for one test; returns the setting to restore.
    private static func pinOpaque() -> Bool? {
        let pinned = ReduceTransparency.shared.override
        ReduceTransparency.shared.override = true
        return pinned
    }

    private static func scope(_ input: ThemeInput, _ name: String) throws -> ThemeScope {
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(name), input: input, animated: false)
        return scope
    }

    /// An inactive window rooted in `scope`.
    private static func window(in scope: ThemeScope) throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scope.root(try #require(window.contentView))
        return window
    }

    private static func dialog() -> CmuxDialogView {
        CmuxDialogView(spec: CmuxDialogSpec(
            title: "Export Your Passwords",
            lines: ["Open the Passwords app.", "Choose File > Export All Passwords and save the CSV file."], origin: "cmux",
            buttons: [.cancel(), .ok("Choose File")]))
    }

    private static func show(_ dialog: CmuxDialogView, in window: NSWindow) throws {
        let root = try #require(window.contentView)
        dialog.removeFromSuperview()
        root.addSubview(dialog)
        root.layoutSubtreeIfNeeded()
    }

    @Test func aDialogMovedIntoALightWindowDrawsReadableText() throws {
        let pinned = Self.pinOpaque()
        defer { ReduceTransparency.shared.override = pinned }
        let darkWindow = try Self.window(in: try Self.scope(Self.dark, "Contrast Dark"))
        let lightScope = try Self.scope(Self.light, "Contrast Light")
        let lightWindow = try Self.window(in: lightScope)
        defer { darkWindow.close(); lightWindow.close() }
        let dialog = Self.dialog()
        try Self.show(dialog, in: darkWindow)
        try Self.show(dialog, in: lightWindow)
        #expect(!lightWindow.isKeyWindow)
        try Self.expectReadable(dialog, in: lightScope)
    }

    /// The mirror case: whichever theme the app scope has when the dialog is built, one of the
    /// two moves lands it in the other one.
    @Test func aDialogMovedIntoADarkWindowDrawsReadableText() throws {
        let pinned = Self.pinOpaque()
        defer { ReduceTransparency.shared.override = pinned }
        let lightWindow = try Self.window(in: try Self.scope(Self.light, "Contrast Light First"))
        let darkScope = try Self.scope(Self.dark, "Contrast Dark Second")
        let darkWindow = try Self.window(in: darkScope)
        defer { lightWindow.close(); darkWindow.close() }
        let dialog = Self.dialog()
        try Self.show(dialog, in: lightWindow)
        try Self.show(dialog, in: darkWindow)
        try Self.expectReadable(dialog, in: darkScope)
    }

    @Test func aDialogWhoseThemeTurnsLightDrawsReadableText() throws {
        let pinned = Self.pinOpaque()
        defer { ReduceTransparency.shared.override = pinned }
        let scope = try Self.scope(Self.dark, "Contrast Switch")
        let window = try Self.window(in: scope)
        defer { window.close() }
        let dialog = Self.dialog()
        try Self.show(dialog, in: window)
        scope.setOverride(ThemeSpec("Contrast Switch Light"), input: Self.light, animated: false)
        #expect(!window.isKeyWindow)
        try Self.expectReadable(dialog, in: scope)
    }

    @Test func aDarkDialogDrawsItsWindowsInk() throws {
        let pinned = Self.pinOpaque()
        defer { ReduceTransparency.shared.override = pinned }
        let scope = try Self.scope(Self.dark, "Contrast Dark Only")
        let window = try Self.window(in: scope)
        defer { window.close() }
        let dialog = Self.dialog()
        try Self.show(dialog, in: window)
        let surface = try Self.surfaceFill(dialog)
        #expect(Self.distance(surface, scope.perform { Palette.popupSurface }) < 0.01)
        for label in Self.labels(in: dialog) {
            let color = try #require(label.textColor)
            let inks = scope.perform { [Palette.textPrimary, Palette.textSecondary] }
            #expect(inks.contains { Self.distance(color, $0) < 0.01 }, "\(label.stringValue)")
        }
    }

    // MARK: Checks

    /// Every label is at least 4.5:1 on the resolved surface, and the surface is the scope's popup
    /// surface, at least as light as the page.
    private static func expectReadable(_ dialog: CmuxDialogView, in scope: ThemeScope) throws {
        let surface = try surfaceFill(dialog)
        let page = scope.perform { Palette.windowBackground }
        #expect(distance(surface, scope.perform { Palette.popupSurface }) < 0.01, "the surface is the theme's popup surface")
        #expect(luminance(surface) >= luminance(page) - 0.001, "the surface is no darker than the page")
        let labels = labels(in: dialog)
        #expect(labels.count >= 4)
        for label in labels {
            let ink = try #require(label.textColor)
            #expect(contrast(ink, surface) >= 4.5, "\(label.stringValue): \(contrast(ink, surface)):1")
        }
        // Button titles over their fill, itself over the surface.
        for button in dialog.buttonViews {
            let fill = try #require(button.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
            let ink = try #require(button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            let under = composite(fill, over: surface)
            #expect(contrast(ink, under) >= 4.5, "\(button.button.title): \(contrast(ink, under)):1")
        }
    }

    private static func composite(_ top: NSColor, over bottom: NSColor) -> NSColor {
        let (r, g, b, a) = rgb(top)
        let (br, bg, bb, _) = rgb(bottom)
        return NSColor(srgbRed: r * a + br * (1 - a), green: g * a + bg * (1 - a), blue: b * a + bb * (1 - a), alpha: 1)
    }

    private static func surfaceFill(_ dialog: CmuxDialogView) throws -> NSColor {
        let surface = try #require(dialog.surface)
        let fill = surface.subviews.lazy.compactMap { $0.layer?.backgroundColor }.first
        return try #require(fill.flatMap(NSColor.init(cgColor:)))
    }

    /// The dialog's text labels; a button's own title view is the button's (checked by `buttons`).
    private static func labels(in view: NSView) -> [any ShownText] {
        if view is NSButton { return [] }
        var found: [any ShownText] = []
        if let label = view as? ChromeLabel, !label.stringValue.isEmpty { found.append(label) }
        if let field = view as? NSTextField, !field.isEditable, !field.stringValue.isEmpty { found.append(field) }
        for subview in view.subviews { found += labels(in: subview) }
        return found
    }

    private static func rgb(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        let (r, g, b, _) = rgb(color)
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast of `ink` composited over the opaque `surface`.
    private static func contrast(_ ink: NSColor, _ surface: NSColor) -> CGFloat {
        let flat = composite(ink, over: surface)
        let (l1, l2) = (luminance(flat), luminance(surface))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private static func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let (a, b) = (rgb(lhs), rgb(rhs))
        return max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2), abs(a.3 - b.3))
    }
}
