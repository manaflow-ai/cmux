import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// The accent is never orange: with the macOS accent set to orange (System Settings > Appearance),
/// cmux's menus, selections and focus rings still draw the theme's own colors, which are neutral
/// grays by default. AppKit paints the system accent into an NSMenu's highlight, a table's
/// selection, a bezel and a focus ring unless the view draws its own; pane-toolbar found a menu
/// highlighted in it (2026-10-20). The web side is webviews/test/accent-glass-invariants.test.ts.
///
/// The suite sets the accent to orange for this process (`AppleAccentColor` 1 is orange) and also
/// compares against `NSColor.systemOrange`, so the check holds where AppKit keeps the host's accent.
@MainActor @Suite(.serialized) final class SystemAccentOrangeTests {
    init() {
        // The argument domain, as `-AppleAccentColor 1` on the command line: in memory only, so the
        // test host's own defaults keep their accent.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleAccentColor"] = 1
        arguments["AppleHighlightColor"] = "1.000000 0.874510 0.701961 Orange"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        _ = NSApplication.shared
    }

    /// Other suites in this process see the host's accent again.
    deinit {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleAccentColor"] = nil
        arguments["AppleHighlightColor"] = nil
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
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

    /// Case (a): the default theme shows no orange anywhere.
    @Test func theDefaultThemesAccentColorsAreNeitherOrangeNorTheSystemAccent() {
        for (name, color) in Self.accentColors(in: Self.neutralScope()) { Self.expectNotAccent(color, name) }
    }

    /// Case (b): a theme on schemas/theme/orange-accent-allowlist.json (Clay Orange: the person
    /// picked an orange theme) keeps its own orange accent, and still never the system accent.
    @Test func anAllowlistedOrangeThemeKeepsItsAccentButNeverTheSystemAccent() throws {
        let themes = try Self.orangeAllowlist()
        for theme in themes {
            let scope = try Self.scope(themeFile: theme)
            for (name, color) in Self.accentColors(in: scope) {
                Self.expectNotAccent(color, "\(theme) \(name)", orangeAllowed: true)
            }
        }
    }

    @Test func aSelectedTableRowIsNotTheSystemAccent() throws {
        let row = ThemedTableRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let scope = Self.neutralScope()
        ThemeScopeRegistry.setScope(scope, of: row)
        row.isSelected = true
        #expect(row.isEmphasized == false, "an emphasized row turns its text white on the accent")
        Self.expectNotAccent(try #require(Self.sample(row, x: 100)), "selected table row")
        withExtendedLifetime(scope) {}
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

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every theme the allowlist names (one entry may name a dark and light pair).
    private static func orangeAllowlist() throws -> [String] {
        struct Allowlist: Decodable { struct Entry: Decodable { let themes: [String] }; let allowed: [Entry] }
        let data = try Data(contentsOf: repoRoot.appending(path: "schemas/theme/orange-accent-allowlist.json"))
        return try JSONDecoder().decode(Allowlist.self, from: data).allowed.flatMap(\.themes)
    }

    /// A shipped cmux theme as the app reads it: background, foreground and its `# cmux-accent`.
    private static func scope(themeFile name: String) throws -> ThemeScope {
        let text = try String(contentsOf: repoRoot.appending(path: "Resources/cmux-themes/\(name)"), encoding: .utf8)
        func value(_ key: String) -> ThemeRGB? {
            text.split(separator: "\n").lazy.compactMap { line -> ThemeRGB? in
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 && parts[0] == key ? ThemeRGB(cssHex: parts[1]) : nil
            }.first
        }
        var input = ThemeInput(background: try #require(value("background")), foreground: try #require(value("foreground")))
        let accent: ThemeRGB = try #require(value("# cmux-accent"), "\(name) names its accent")
        input.accentColor = accent
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(name), input: input, animated: false)
        return scope
    }

    /// The palette's accent colors in `scope`, resolved there (a dynamic color would resolve against
    /// the app theme once the scope is popped).
    private static func accentColors(in scope: ThemeScope) -> [(String, NSColor)] {
        ThemeContext.push(scope)
        defer { ThemeContext.pop() }
        let colors = [("accent", Palette.accent), ("accentFill", Palette.accentFill), ("focusRing", Palette.focusRing),
                      ("menuHighlight", Palette.menuHighlight), ("selectionFill", Palette.selectionFill)]
        return colors.map { ($0.0, $0.1.usingColorSpace(.sRGB) ?? $0.1) }
    }

    private static func expectNotAccent(_ color: NSColor, _ name: String, orangeAllowed: Bool = false,
                                        sourceLocation: SourceLocation = #_sourceLocation) {
        guard let rgb = color.usingColorSpace(.sRGB), rgb.alphaComponent > 0.02 else { return }
        if !orangeAllowed { #expect(!isOrange(rgb), "\(name) \(rgb) is orange", sourceLocation: sourceLocation) }
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

    /// Past red (system red is about 29°) and short of yellow (about 95°); macOS orange is 64–68°,
    /// Clay Orange's clay 38°.
    private static func isOrange(_ color: NSColor) -> Bool {
        let (chroma, hue) = lch(color)
        return chroma >= 0.1 && hue >= 35 && hue <= 78
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
