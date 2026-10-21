import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing

/// The accent is never orange: with the macOS accent set to orange (System Settings > Appearance),
/// cmux's menus, selections and focus rings still draw the theme's own colors, which are neutral
/// grays by default. AppKit paints the system accent into an NSMenu's highlight, a table's
/// selection, a bezel and a focus ring unless the view draws its own; pane-toolbar found a menu
/// highlighted in it (2026-10-20). The web side is webviews/test/accent-glass-invariants.test.ts.
///
/// The suite sets the accent to orange for this process (`AppleAccentColor` 1 is orange) and also
/// compares against `NSColor.systemOrange`, so the check holds where AppKit keeps the host's accent.
@MainActor @Suite(.serialized) struct SystemAccentOrangeTests {
    init() {
        // The argument domain, as `-AppleAccentColor 1` on the command line: in memory only, so the
        // test host's own defaults keep their accent.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleAccentColor"] = 1
        arguments["AppleHighlightColor"] = "1.000000 0.874510 0.701961 Orange"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        _ = NSApplication.shared
    }

    /// The app's default look: a dark theme with no accent of its own and `appearance.accent` neutral.
    private static func neutralScope() -> ThemeScope {
        let input = ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xFFFFFF))
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Neutral"), input: input, animated: false)
        return scope
    }

    /// The colors macOS draws for its accent, orange included whatever the host's accent is.
    private static var systemAccents: [(String, NSColor)] {
        [("controlAccentColor", .controlAccentColor), ("selectedContentBackgroundColor", .selectedContentBackgroundColor),
         ("keyboardFocusIndicatorColor", .keyboardFocusIndicatorColor), ("selectedTextBackgroundColor", .selectedTextBackgroundColor),
         ("systemOrange", .systemOrange)]
    }

    @Test func theDefaultThemesAccentColorsAreNeitherOrangeNorTheSystemAccent() {
        let scope = Self.neutralScope()
        ThemeContext.push(scope)
        defer { ThemeContext.pop() }
        let colors: [(String, NSColor)] = [("accent", Palette.accent), ("accentFill", Palette.accentFill),
                                           ("focusRing", Palette.focusRing), ("menuHighlight", Palette.menuHighlight),
                                           ("selectionFill", Palette.selectionFill)]
        for (name, color) in colors { Self.expectNotAccent(color, name) }
    }

    @Test func aThemedMenuHighlightIsNotTheSystemAccent() throws {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Rename", action: nil, keyEquivalent: ""))
        menu.themeRows(in: Self.neutralScope())
        let row = try #require(menu.items[0].view as? ThemedMenuRowView, "the row is cmux-drawn, not AppKit's highlight")
        row.highlightOverride = true
        // Left of the title, where only the highlight paints.
        Self.expectNotAccent(try #require(Self.sample(row, x: 8)), "highlighted menu row")
    }

    @Test func aSelectedTableRowIsNotTheSystemAccent() throws {
        let row = ThemedTableRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        ThemeScopeRegistry.setScope(Self.neutralScope(), of: row)
        row.isSelected = true
        #expect(row.isEmphasized == false, "an emphasized row turns its text white on the accent")
        Self.expectNotAccent(try #require(Self.sample(row, x: 100)), "selected table row")
    }

    @Test func aBezelButtonIsNotTheSystemAccent() throws {
        let button = ThemedBezelButton(frame: NSRect(x: 0, y: 0, width: 120, height: 28))
        Self.expectNotAccent(try #require(button.bezelColor), "bezel button")
    }

    /// AppKit's focus ring is the system accent; cmux's fields draw their own.
    @Test func textFieldsDrawNoSystemFocusRing() {
        #expect(ThemedTextField(frame: .zero).focusRingType == .none)
        #expect(ThemedSecureTextField(frame: .zero).focusRingType == .none)
    }

    // MARK: Helpers

    private static func expectNotAccent(_ color: NSColor, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let rgb = color.usingColorSpace(.sRGB), rgb.alphaComponent > 0.02 else { return }
        #expect(!isOrange(rgb), "\(name) \(rgb) is orange", sourceLocation: sourceLocation)
        for (systemName, system) in systemAccents {
            guard let system = system.usingColorSpace(.sRGB), chroma(system) >= 0.04 else { continue }
            #expect(distance(rgb, system) > 0.08, "\(name) \(rgb) is \(systemName) \(system)", sourceLocation: sourceLocation)
        }
    }

    /// OKLCH chroma and hue in degrees.
    private static func lch(_ color: NSColor) -> (chroma: CGFloat, hue: CGFloat) {
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (r, g, b) = (linear(color.redComponent), linear(color.greenComponent), linear(color.blueComponent))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let a = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
        let hue = atan2(bb, a) * 180 / .pi
        return (hypot(a, bb), hue < 0 ? hue + 360 : hue)
    }

    private static func chroma(_ color: NSColor) -> CGFloat { lch(color).chroma }

    /// Past red (system red is about 29°) and short of yellow (about 95°); macOS orange is 64–68°.
    private static func isOrange(_ color: NSColor) -> Bool {
        let (chroma, hue) = lch(color)
        return chroma >= 0.1 && hue >= 40 && hue <= 78
    }

    private static func sample(_ view: NSView, x: CGFloat) -> NSColor? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return rep.colorAt(x: Int(x * scale), y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
    }

    private static func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        max(abs(lhs.redComponent - rhs.redComponent), abs(lhs.greenComponent - rhs.greenComponent),
            abs(lhs.blueComponent - rhs.blueComponent))
    }
}
