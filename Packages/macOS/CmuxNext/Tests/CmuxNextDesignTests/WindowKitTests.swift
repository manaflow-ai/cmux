import AppKit
import Testing
@testable import CmuxNextDesign

/// The window kit (plans/cmux-next/windows.md): `NSWindow.install` is the
/// only way a window gets its content; it records the kind, enforces a
/// close button, adopts the scope and paints the one surface token before
/// the content goes in.
@MainActor @Suite(.serialized) struct WindowKitTests {
    private func window(_ style: NSWindow.StyleMask = [.resizable]) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 320, height: 200),
                              styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func expectClose(_ color: NSColor?, to rgb: ThemeRGB, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let color = color?.usingColorSpace(.sRGB) else {
            Issue.record("no color", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(color.redComponent - rgb.red) < 0.01, sourceLocation: sourceLocation)
        #expect(abs(color.greenComponent - rgb.green) < 0.01, sourceLocation: sourceLocation)
        #expect(abs(color.blueComponent - rgb.blue) < 0.01, sourceLocation: sourceLocation)
    }

    @Test func installRecordsTheKindAndEnforcesTheCloseButton() {
        for kind in WindowKind.allCases {
            let window = window()
            #expect(window.windowKind == nil)
            window.install(kind: kind, content: NSView(), scope: .app)
            #expect(window.windowKind == kind)
            #expect(window.styleMask.isSuperset(of: [.titled, .closable]), "\(kind)")
            #expect(window.standardWindowButton(.closeButton) != nil, "\(kind)")
            #expect(window.standardWindowButton(.zoomButton)?.isHidden == kind.traits.hidesMinimizeAndZoom, "\(kind)")
        }
    }

    /// One backdrop: every kind but main gets a `WindowSurfaceView` that
    /// draws the main window's backdrop: opaque, the solid token; see-through,
    /// the token as the tint at the theme's opacity over a clear window.
    @Test(arguments: [1.0, 0.6])
    func everyKindShowsTheOneBackdrop(opacity: Double) throws {
        var input = ThemeFixtures.catppuccinMocha
        input.backgroundOpacity = opacity
        let room = ThemeScope(level: .room)
        room.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input, animated: false)
        let token = ThemeTokens.derive(from: input).surfaceBackground
        for kind in WindowKind.allCases where kind.traits.surface == .backdrop {
            let window = window()
            let content = NSView()
            window.install(kind: kind, content: content, scope: room)
            let surface = try #require(window.contentView as? WindowSurfaceView, "\(kind)")
            #expect(window.installedContent === content)
            #expect(surface.backdropView.superview === surface && surface.subviews.first === surface.backdropView)
            if opacity == 1 {
                #expect(window.isOpaque, "\(kind)")
                Self.expectClose(window.backgroundColor, to: token)
                Self.expectClose(surface.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }, to: token)
                #expect(surface.backdropView.tintColor == nil)
            } else {
                #expect(!window.isOpaque, "\(kind)")
                #expect((window.backgroundColor?.alphaComponent ?? 1) < 0.01, "\(kind)")
                #expect(surface.layer?.backgroundColor == nil, "\(kind)")
                let tint = surface.backdropView.tintColor.flatMap { NSColor(cgColor: $0) }
                Self.expectClose(tint, to: token)
                #expect(abs((tint?.alphaComponent ?? 0) - opacity) < 0.01, "\(kind)")
            }
        }
    }

    @Test func aScopeChangeRepaintsTheBackdrop() {
        let room = ThemeScope(level: .room)
        let window = window()
        window.install(kind: .settings, content: NSView(), scope: room)
        var input = ThemeFixtures.catppuccinMocha
        input.backgroundOpacity = 0.6
        room.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input, animated: false)
        #expect(!window.isOpaque)
        input.backgroundOpacity = 1
        room.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input, animated: false)
        #expect(window.isOpaque)
        Self.expectClose(window.backgroundColor, to: ThemeTokens.derive(from: input).surfaceBackground)
    }

    @Test func mainLeavesTheBackdropToItsContent() {
        final class Painter: NSView, WindowSurfacePainting {
            var painted = 0
            var hadContent = true
            func paintWindowSurface(of window: NSWindow) {
                painted += 1
                hadContent = window.contentView === self
            }
        }
        let main = window()
        let painter = Painter()
        main.install(kind: .main, content: painter, scope: .app)
        #expect(main.contentView === painter, "main is not wrapped")
        #expect(painter.painted == 1)
        #expect(!painter.hadContent, "the backdrop goes in before the content view")
    }

    /// A palette or sheet over a window acts as that window's kind; a popup
    /// (a child with a kind of its own) as its own.
    @Test func rootResolution() {
        let main = window([.titled, .closable])
        main.install(kind: .main, content: NSView(), scope: .app)
        let palette = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        main.addChildWindow(palette, ordered: .above)
        defer { main.removeChildWindow(palette) }
        #expect(palette.windowKindRoot === main)
        #expect(palette.windowKind == nil)
        let popup = window()
        popup.install(kind: .browserPopup, content: NSView(), scope: .app)
        main.addChildWindow(popup, ordered: .above)
        defer { main.removeChildWindow(popup) }
        #expect(popup.windowKindRoot === popup)
        let page = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        popup.addChildWindow(page, ordered: .above)
        defer { popup.removeChildWindow(page) }
        #expect(page.windowKindRoot === popup)
        let loose = window()
        #expect(loose.windowKindRoot === loose)
    }

    @Test func rawValuesAreTheSnapshotKinds() {
        #expect(WindowKind.allCases.map(\.rawValue) == [
            "main", "settings", "debugSettings", "appStore", "onboarding", "onboardingGallery",
            "browserPopup", "devTools", "pageInfo", "terminalDebug", "browserDebug",
        ])
    }
}
