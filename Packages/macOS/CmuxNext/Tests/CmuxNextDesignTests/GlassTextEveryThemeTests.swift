import AppKit
import CmuxNextTestSupport
import CmuxTheme
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// User 2026-11-03: "we need to make sure every single theme, all the UI elements are colored
/// properly". A toast and a sheet draw on the role glass: a veil (``FloatingGlassStyle``; the
/// toast's in the theme's tint, the sheet's grey) over the window, or the solid popup surface under Reduce Transparency. Their text was the
/// theme's text colours as they are, never fitted to that glass, so in low-contrast themes the
/// message and the detail read under 4.5:1; a toast also took its colours once, outside any
/// window, so in a room with its own theme it kept the app theme's ink, and its hidden detail kept
/// the theme it was made in until Details showed it. In every bundled theme the text reads on each
/// ground it can show: 4.5:1, the code line (a hint) 3:1. The sheet (a cmux dialog) is the overlay
/// page's now; its text is checked in the webviews gallery (pages.overlay.dialog).
@MainActor @Suite(.serialized, .closesItsWindows)
struct GlassTextEveryThemeTests {
    private static func ground(_ style: FloatingGlassStyle, _ tokens: ThemeTokens) -> ThemeRGB {
        Palette.veilRGB(of: style, tokens: tokens).composited(over: tokens.windowBackground.withAlpha(1))
    }

    private static func rgb(_ color: NSColor?) throws -> ThemeRGB {
        let c = try #require(color?.usingColorSpace(.sRGB))
        return ThemeRGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
    }

    @Test func toastTextReadsOnItsGlassInEveryBundledTheme() throws {
        let themes = try CardNeverOpaqueTests.bundledThemes()
        #expect(themes.count > 600)
        let scope = ThemeScope(level: .room)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try #require(window.contentView)
        scope.setOverride(try #require(ThemeSpec("Glass \(themes[0].name)")), input: themes[0].input, animated: false)
        scope.root(root)
        // A Details action, so the toast makes its detail label. One toast on the glass, one on the
        // opaque surface (Reduce Transparency): each fits its text to the ground it shows, as no one
        // ink reads on both in every theme (Hot Dog Stand: white on the veiled red, black on the lifted one).
        func makeToast(_ reduceTransparency: ReduceTransparency) -> CmuxToastView {
            CmuxToastView(toast: CmuxToast(id: "t", message: "Could not save the file", detail: "The disk is full.",
                                           action: .details("Details")), reduceTransparency: reduceTransparency)
        }
        let glassToast = makeToast(ReduceTransparency(system: { false }, changes: NotificationCenter()))
        let opaqueToast = makeToast(.alwaysOpaque)
        root.addSubview(glassToast)
        root.addSubview(opaqueToast)
        root.layoutSubtreeIfNeeded()
        var failures: [String] = []
        for theme in themes {
            // The theme changes while the detail is hidden, then Details shows it, as a person sees it.
            glassToast.setShowsDetails(false)
            opaqueToast.setShowsDetails(false)
            scope.setOverride(try #require(ThemeSpec("Glass \(theme.name)")), input: theme.input, animated: false)
            glassToast.setShowsDetails(true)
            opaqueToast.setShowsDetails(true)
            let tokens = scope.tokens
            let shown: [(String, CmuxToastView, ThemeRGB)] = [
                ("glass", glassToast, Self.ground(.toast, tokens)),
                ("opaque", opaqueToast, tokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value)),
            ]
            for (surface, toast, ground) in shown {
                let texts: [(String, NSColor?)] = [("message", toast.messageLabel?.textColor), ("detail", toast.detailLabel?.textColor)]
                for (name, color) in texts {
                    let ink = try Self.rgb(color)
                    if ink.contrast(with: ground) < ThemeTokens.minimumTextContrast - 0.01 {
                        failures.append(String(format: "%@: %@ toast %@ %.2f:1", theme.label, surface, name, ink.contrast(with: ground)))
                    }
                }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) failures; first:\n" + failures.prefix(60).joined(separator: "\n")))
    }
}
