import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import Testing

/// The window root hosts the window's one material as its bottom subview,
/// with one theme tint at the resolved opacity, and paints the solid
/// background itself only while opaque (#16688).
@MainActor
@Suite(.serialized)
struct WindowRootMaterialTests {
    private static let mocha = ThemeInput(background: ThemeRGB(hex: 0x1E1E2E), foreground: ThemeRGB(hex: 0xCDD6F4))

    private final class Flag {
        var on: Bool
        init(_ on: Bool) { self.on = on }
    }

    /// A root in a room scope showing `input`, with Reduce Transparency
    /// pinned by `reduceTransparency` (the host setting differs between
    /// machines).
    private func makeRoot(_ input: ThemeInput, reduceTransparency: Flag = Flag(false)) -> (WindowRootView, ThemeScope) {
        let model = SidebarModel()
        let root = WindowRootView(sidebar: SidebarContainerView(model: model),
                                  rail: WindowRailView(model: model, registry: ActionBindingCoverageTests.boundServices().registry),
                                  reduceTransparency: { reduceTransparency.on },
                                  applyWindowBlur: { _, _ in })
        let room = ThemeScope(level: .room)
        room.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input, animated: false)
        room.root(root)
        root.themeDidChange()
        return (root, room)
    }

    private func input(opacity: Double, blur: Int) -> ThemeInput {
        var input = Self.mocha
        input.backgroundOpacity = opacity
        input.backgroundBlur = blur
        return input
    }

    /// Material views the root hosts outside the sidebar (whose own chrome
    /// backdrop cc-pane-chrome moves onto this one).
    private func rootMaterialViews(_ root: WindowRootView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            for child in view.subviews where !(child is SidebarContainerView) {
                if child is NSVisualEffectView || child is NSGlassEffectView { found.append(child) }
                walk(child)
            }
        }
        walk(root)
        return found
    }

    @Test(arguments: [(1.0, -1), (0.6, -2)])
    func aGlassRootHostsExactlyOneMaterialAtTheBottom(opacity: Double, blur: Int) throws {
        let (root, room) = makeRoot(input(opacity: opacity, blur: blur))
        let materials = rootMaterialViews(root)
        #expect(materials.count == 1)
        #expect(materials.first is NSGlassEffectView)
        #expect(root.subviews.first === root.backdropView, "the material is the bottom subview")
        // The tint replaces the root's own translucent paint.
        #expect(root.layer?.backgroundColor == nil)
        let tint = try #require(root.backdropView.tintColor)
        #expect(abs(tint.alpha - opacity) < 0.001)
        withExtendedLifetime(room) {}
    }

    /// A frosted root hosts no material view: the tint at the opacity over
    /// the desktop, which the window's blur radius frosts. A behind-window
    /// NSVisualEffectView made the window opaque.
    @Test(arguments: [(0.8, 20), (0.5, 1)])
    func aFrostedRootHostsOnlyTheTint(opacity: Double, blur: Int) throws {
        let (root, room) = makeRoot(input(opacity: opacity, blur: blur))
        #expect(root.backdrop.material == .frosted)
        #expect(root.backdrop.setsWindowBlurRadius)
        #expect(rootMaterialViews(root).isEmpty)
        #expect(root.layer?.backgroundColor == nil)
        let tint = try #require(root.backdropView.tintColor)
        #expect(abs(tint.alpha - opacity) < 0.001)
        withExtendedLifetime(room) {}
    }

    /// A translucent config with no blur is plainly see-through: no
    /// material view, the tint at the opacity, and a clear root layer.
    @Test func aSeeThroughRootHostsOnlyTheTint() throws {
        let (root, room) = makeRoot(input(opacity: 0.7, blur: 0))
        #expect(root.backdrop.material == .translucent)
        #expect(rootMaterialViews(root).isEmpty)
        #expect(root.layer?.backgroundColor == nil)
        let tint = try #require(root.backdropView.tintColor)
        #expect(abs(tint.alpha - 0.7) < 0.001)
        withExtendedLifetime(room) {}
    }

    @Test func anOpaqueRootHostsNoMaterialAndPaintsSolid() throws {
        let (root, room) = makeRoot(input(opacity: 1, blur: 20))
        #expect(rootMaterialViews(root).isEmpty)
        #expect(root.backdropView.tintColor == nil)
        let paint = try #require(root.layer?.backgroundColor)
        #expect(paint.alpha == 1)
        withExtendedLifetime(room) {}
    }

    /// Reduce Transparency falls back to opaque, live on the display-options
    /// notification.
    @Test func reduceTransparencyMakesTheRootOpaque() throws {
        let reduce = Flag(true)
        let (root, room) = makeRoot(input(opacity: 0.7, blur: 20), reduceTransparency: reduce)
        #expect(rootMaterialViews(root).isEmpty)
        #expect(root.backdrop.material == .opaque)
        #expect(try #require(root.layer?.backgroundColor).alpha == 1, "solid, not the translucent background")

        reduce.on = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(root.backdrop.material == .frosted)
        #expect(try #require(root.backdropView.tintColor).alpha < 1)
        #expect(root.layer?.backgroundColor == nil)
        withExtendedLifetime(room) {}
    }

    /// A theme change swaps the one material; it never stacks a second.
    @Test func aThemeChangeSwapsTheMaterial() {
        let (root, room) = makeRoot(input(opacity: 0.8, blur: 20))
        room.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input(opacity: 0.8, blur: -1), animated: false)
        root.themeDidChange()
        #expect(rootMaterialViews(root).count == 1)
        #expect(rootMaterialViews(root).first is NSGlassEffectView)
        room.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input(opacity: 1, blur: 0), animated: false)
        root.themeDidChange()
        #expect(rootMaterialViews(root).isEmpty)
        withExtendedLifetime(room) {}
    }

    /// The window over a material is non-opaque with Ghostty's 0.001 white,
    /// and opaque with the solid background otherwise.
    @Test func theWindowFollowsTheMaterial() throws {
        let (root, room) = makeRoot(input(opacity: 0.8, blur: 0))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        root.applyBackdrop(to: window)
        #expect(!window.isOpaque)
        #expect(abs((window.backgroundColor?.alphaComponent ?? 1) - 0.001) < 0.0001)
        room.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input(opacity: 1, blur: 0), animated: false)
        root.applyBackdrop(to: window)
        #expect(window.isOpaque)
        #expect(window.backgroundColor?.alphaComponent == 1)
        withExtendedLifetime(room) {}
    }
}
