import AppKit
import CmuxNextTestSupport
import CmuxTheme
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// User 2026-11-03: "we need to make sure every single theme, all the UI elements are colored
/// properly". A toast and a sheet draw on the neutral glass: a grey veil (``FloatingGlassStyle``)
/// over the window, or the solid popup surface under Reduce Transparency. Their text was the
/// theme's text colours as they are, never fitted to that glass, so in low-contrast themes the
/// message and the detail read under 4.5:1; a toast also took its colours once, outside any
/// window, so in a room with its own theme it kept the app theme's ink, and its hidden detail kept
/// the theme it was made in until Details showed it. In every bundled theme the sheet's text reads
/// on each ground it can show: 4.5:1, the code line (a hint) 3:1. (Toasts are the web toast stack
/// now; their colours come from the page's theme.)
@MainActor @Suite(.serialized, .closesItsWindows)
struct GlassTextEveryThemeTests {
    private static func rgb(_ color: NSColor?) throws -> ThemeRGB {
        let c = try #require(color?.usingColorSpace(.sRGB))
        return ThemeRGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
    }

    private static func dialogLabels(in view: NSView) -> [NSTextField] {
        if view is NSButton { return [] }
        var found: [NSTextField] = []
        if let field = view as? NSTextField, !field.isEditable, !field.stringValue.isEmpty { found.append(field) }
        for subview in view.subviews { found += dialogLabels(in: subview) }
        return found
    }

    @Test func sheetTextReadsOnItsGlassInEveryBundledTheme() throws {
        let themes = try CardNeverOpaqueTests.bundledThemes()
        #expect(themes.count > 600)
        let scope = ThemeScope(level: .room)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try #require(window.contentView)
        scope.setOverride(try #require(ThemeSpec("Glass \(themes[0].name)")), input: themes[0].input, animated: false)
        scope.root(root)
        let dialog = CmuxDialogView(spec: CmuxDialogSpec(title: "Export Your Passwords", lines: ["Open the Passwords app."],
                                                         origin: "cmux", buttons: [.cancel(), .ok("Choose File")]))
        root.addSubview(dialog)
        root.layoutSubtreeIfNeeded()
        var failures: [String] = []
        for theme in themes {
            scope.setOverride(try #require(ThemeSpec("Glass \(theme.name)")), input: theme.input, animated: false)
            let tokens = scope.tokens
            for label in Self.dialogLabels(in: dialog) {
                let ink = try Self.rgb(label.textColor)
                for ground in CmuxDialogButtonLook.cardSurfaces(tokens) where ink.contrast(with: ground) < ThemeTokens.minimumTextContrast - 0.01 {
                    failures.append(String(format: "%@: sheet \"%@\" %.2f:1", theme.label, label.stringValue, ink.contrast(with: ground)))
                }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) failures; first:\n" + failures.prefix(60).joined(separator: "\n")))
    }
}
