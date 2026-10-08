import AppKit
import CmuxNextDesign
import CmuxTheme
@testable import CmuxNextHome
import Testing

/// Lawrence (hq-6d, 2026-10-07): every part of Home (people list, its header
/// strip, search area, tiles, transcript, its header, composer) lets the
/// window's background image show through, in light and dark. A view may lay
/// only a translucent scrim (`Palette.legibilityScrim`), never an opaque
/// background and never a within-window vibrancy material (it drew a solid
/// gray panel, f8ae54c4e2f7).
@MainActor @Suite(.serialized) struct HomeTransparencyTests {
    /// A see-through room scope, light or dark, at `opacity`.
    static func scope(light: Bool, opacity: Double = 0.55) -> ThemeScope {
        let scope = ThemeScope(level: .room)
        var input = ThemeScope.app.input
        input.background = ThemeRGB(hex: light ? 0xFFFFFF : 0x1E1E2E)
        input.foreground = ThemeRGB(hex: light ? 0x1F2328 : 0xCDD6F4)
        input.backgroundOpacity = opacity
        scope.setOverride(ThemeSpec(light ? "GitHub Light" : "Catppuccin Mocha")!, input: input, animated: false)
        return scope
    }

    /// The people list and the transcript side by side in a see-through window.
    static func home(light: Bool) async -> (NSWindow, HomeSidebarView, HomeNativeTranscriptView) {
        let (window, transcript, _) = await HomeFirstRunTests.view()
        let theme = scope(light: light)
        theme.adopt(window)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 948, height: 700))
        let sidebar = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 700))
        transcript.frame = NSRect(x: 320, y: 0, width: 628, height: 700)
        content.addSubview(sidebar)
        content.addSubview(transcript)
        window.setContentSize(content.frame.size)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        sidebar.viewDidChangeEffectiveAppearance()
        transcript.viewDidChangeEffectiveAppearance()
        content.displayIfNeeded()
        return (window, sidebar, transcript)
    }

    /// Views that paint a background: at least 100 x 40 pt (a mark such as
    /// an unread dot or a badge is not a background). Controls draw their
    /// own bezels and are not walked.
    static func backgrounds(under view: NSView) -> [NSView] {
        guard !(view is NSControl) else { return [] }
        return [view] + view.subviews.filter { !$0.isHidden }.flatMap(backgrounds(under:))
    }

    static func opaque(_ color: CGColor?) -> Bool { (color?.alpha ?? 0) >= 0.999 }

    @Test(arguments: [false, true])
    func noHomeViewHidesTheWindowBackground(light: Bool) async {
        let (window, sidebar, transcript) = await Self.home(light: light)
        defer { window.close() }
        for view in Self.backgrounds(under: sidebar) + Self.backgrounds(under: transcript) {
            let name = "\(type(of: view)) \(view.frame)"
            if let effect = view as? NSVisualEffectView {
                #expect(effect.blendingMode != .withinWindow, "\(name) is a within-window material over the image")
            }
            guard view.bounds.width >= 100, view.bounds.height >= 40 else { continue }
            #expect(!Self.opaque(view.layer?.backgroundColor), "\(name) paints an opaque background")
            if let scroll = view as? NSScrollView {
                #expect(!(scroll.drawsBackground && Self.opaque(scroll.backgroundColor.cgColor)), "\(name) draws an opaque background")
            }
            if let clip = view as? NSClipView {
                #expect(!(clip.drawsBackground && Self.opaque(clip.backgroundColor.cgColor)), "\(name) draws an opaque background")
            }
        }
    }

    @Test(arguments: [false, true])
    func theListScrimIsTheSharedTranslucentScrim(light: Bool) async throws {
        let (window, sidebar, _) = await Self.home(light: light)
        defer { window.close() }
        let scrim = try #require(sidebar.layer?.backgroundColor)
        let expected = Self.scope(light: light).perform { Palette.legibilityScrim.cgColor }
        #expect(scrim.alpha > 0 && scrim.alpha < 1)
        #expect(abs(scrim.alpha - expected.alpha) < 0.01, "the list uses the shared palette scrim")
    }
}
