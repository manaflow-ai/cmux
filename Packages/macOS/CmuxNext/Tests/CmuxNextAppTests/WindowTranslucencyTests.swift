import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import Testing

/// A translucent config keeps the real window see-through: the NSWindow is
/// non-opaque, and nothing in the root paints an opaque sheet over the
/// desktop, with or without a room theme, under a workspace theme.
///
/// The fleet capture behind this (window alpha 255 on every pixel, Ghostty
/// `background-opacity = 0.85` and `background-blur = true`, cmux.json
/// `appearance.backgroundOpacity: 0.85`) came from the frosted material: a
/// window-sized behind-window `NSVisualEffectView` composites the desktop
/// and its own material into an opaque sheet, and the 0.85 tint over it
/// reads as the opaque theme background.
@MainActor
@Suite(.serialized)
struct WindowTranslucencyTests {
    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        let roomTheme: Bool
        let blur: Int
        var testDescription: String { "\(roomTheme ? "room theme" : "no room theme"), background-blur \(blur)" }
    }

    nonisolated static let cases: [Case] = [
        Case(roomTheme: false, blur: 20),
        Case(roomTheme: true, blur: 20),
        Case(roomTheme: false, blur: 0),
        Case(roomTheme: true, blur: 0),
    ]

    private static func mocha(opacity: Double, blur: Int) -> ThemeInput {
        var input = ThemeInput(background: ThemeRGB(hex: 0x1E1E2E), foreground: ThemeRGB(hex: 0xCDD6F4))
        input.backgroundOpacity = opacity
        input.backgroundBlur = blur
        return input
    }

    private final class BlurLog {
        var windows: [NSWindow] = []
    }

    /// Views in `root` that cover most of the window and paint opaquely:
    /// a behind-window effect view, a view that claims `isOpaque`, or a
    /// layer filled at full alpha.
    private func opaqueSheets(in root: NSView) -> [NSView] {
        let area = root.bounds.width * root.bounds.height
        var found: [NSView] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            let frame = view.convert(view.bounds, to: root).intersection(root.bounds)
            if frame.width * frame.height >= area / 2 {
                let effect = (view as? NSVisualEffectView).map { $0.blendingMode == .behindWindow } ?? false
                let filled = (view.layer?.backgroundColor?.alpha ?? 0) >= 1
                if effect || view.isOpaque || filled { found.append(view) }
            }
            for child in view.subviews { walk(child) }
        }
        walk(root)
        return found
    }

    @Test(arguments: cases)
    func aTranslucentConfigKeepsTheWindowSeeThrough(_ c: Case) throws {
        let input = Self.mocha(opacity: 0.85, blur: c.blur)
        // The Ghostty config's theme (cmux.json and Ghostty at 0.85).
        let config = ThemeScope(level: .room)
        config.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input, animated: false)
        let room = ThemeScope(level: .room, parent: config)
        if c.roomTheme { room.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input, animated: false) }

        let blurs = BlurLog()
        let model = SidebarModel()
        let root = WindowRootView(sidebar: SidebarContainerView(model: model),
                                  rail: WindowRailView(model: model, registry: ActionBindingCoverageTests.boundServices().registry),
                                  reduceTransparency: { false },
                                  applyWindowBlur: { window, _ in blurs.windows.append(window) })
        // WindowController's order: backdrop, content view, room scope.
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        root.applyBackdrop(to: window)
        window.contentView = root
        room.adopt(window)

        // The workspace pinned to Catppuccin Mocha (workspace.setTheme).
        let workspace = ThemeScope(level: .workspace)
        let content = NSView()
        workspace.root(content)
        root.show(content)
        workspace.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input, animated: false)
        room.show(workspace)
        root.layoutSubtreeIfNeeded()

        #expect(root.backdrop.material == (c.blur > 0 ? WindowMaterial.frosted : WindowMaterial.translucent))
        #expect(!window.isOpaque)
        #expect((window.backgroundColor?.alphaComponent ?? 1) < 0.01)
        #expect(root.layer?.backgroundColor == nil)
        let tint = try #require(root.backdropView.tintColor)
        #expect(abs(tint.alpha - 0.85) < 0.001)
        let sheets = opaqueSheets(in: root)
        #expect(sheets.isEmpty, "opaque over the desktop: \(sheets.map { String(describing: type(of: $0)) })")
        if c.blur > 0 {
            #expect(blurs.windows.contains { $0 === window }, "the blur radius goes on the window, behind the tint")
        }
        window.close()
        withExtendedLifetime((config, room, workspace)) {}
    }
}
