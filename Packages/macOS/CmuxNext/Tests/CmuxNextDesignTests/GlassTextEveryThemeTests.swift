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
/// the theme it was made in until Details showed it. In every bundled theme the text reads on each
/// ground it can show: 4.5:1, the code line (a hint) 3:1.
@MainActor @Suite(.serialized, .closesItsWindows)
struct GlassTextEveryThemeTests {
    private static func ground(_ style: FloatingGlassStyle, _ tokens: ThemeTokens) -> ThemeRGB {
        let veil = style.look(isDark: tokens.isDark).veil
        return ThemeRGB(red: veil.white, green: veil.white, blue: veil.white, alpha: veil.alpha).composited(over: tokens.windowBackground.withAlpha(1))
    }

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

    @Test func toastAndSheetTextReadsOnItsGlassInEveryBundledTheme() throws {
        let themes = try CardNeverOpaqueTests.bundledThemes()
        #expect(themes.count > 600)
        let scope = ThemeScope(level: .room)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try #require(window.contentView)
        scope.setOverride(try #require(ThemeSpec("Glass \(themes[0].name)")), input: themes[0].input, animated: false)
        scope.root(root)
        // A Details action, so the toast makes its detail label.
        let toast = CmuxToastView(toast: CmuxToast(id: "t", message: "Could not save the file", detail: "The disk is full.",
                                                   action: .details("Details")))
        let dialog = CmuxDialogView(spec: CmuxDialogSpec(title: "Export Your Passwords", lines: ["Open the Passwords app."],
                                                         origin: "cmux", buttons: [.cancel(), .ok("Choose File")]))
        root.addSubview(toast)
        root.addSubview(dialog)
        root.layoutSubtreeIfNeeded()
        var failures: [String] = []
        for theme in themes {
            // The theme changes while the detail is hidden, then Details shows it, as a person sees it.
            toast.setShowsDetails(false)
            scope.setOverride(try #require(ThemeSpec("Glass \(theme.name)")), input: theme.input, animated: false)
            toast.setShowsDetails(true)
            let tokens = scope.tokens
            let toastGrounds = [Self.ground(.toast, tokens), tokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value)]
            let texts: [(String, NSColor?, Double)] = [("toast message", toast.messageLabel?.textColor, ThemeTokens.minimumTextContrast),
                                                      ("toast detail", toast.detailLabel?.textColor, ThemeTokens.minimumTextContrast)]
            for (name, color, minimum) in texts {
                let ink = try Self.rgb(color)
                for ground in toastGrounds where ink.contrast(with: ground) < minimum - 0.01 {
                    failures.append(String(format: "%@: %@ %.2f:1", theme.label, name, ink.contrast(with: ground)))
                }
            }
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
