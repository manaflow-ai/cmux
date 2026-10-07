import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import Testing

/// The window's behind-window blur radius follows the backdrop of the
/// root's own scope: a frosted theme puts its own `background-blur` radius
/// on the window, and every other material clears it (see-through, Liquid
/// Glass, opaque), so a switch never leaves an old blur behind.
@MainActor
@Suite(.serialized)
struct WindowBlurRadiusTests {
    private final class Log {
        var radii: [Int] = []
    }

    private static func mocha(opacity: Double, blur: Int) -> ThemeInput {
        var input = ThemeInput(background: ThemeRGB(hex: 0x1E1E2E), foreground: ThemeRGB(hex: 0xCDD6F4))
        input.backgroundOpacity = opacity
        input.backgroundBlur = blur
        return input
    }

    /// A real window in WindowController's order, in a room drawing
    /// `input`, recording every blur radius the root sets on it.
    private func makeWindow(_ input: ThemeInput, reduceTransparency: Bool = false) -> (WindowRootView, NSWindow, ThemeScope, Log) {
        let log = Log()
        let model = SidebarModel()
        let root = WindowRootView(sidebar: SidebarContainerView(model: model),
                                  reduceTransparency: { reduceTransparency },
                                  applyWindowBlur: { _, radius in log.radii.append(radius) })
        let room = ThemeScope(level: .room)
        room.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input, animated: false)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 500),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Resolve the root against the room before the first backdrop write;
        // otherwise a concurrently changing app theme can leave an initial
        // global blur radius in the test log.
        room.root(root)
        root.applyBackdrop(to: window)
        window.contentView = root
        room.adopt(window)
        root.themeDidChange()
        return (root, window, room, log)
    }

    /// A theme that sets its own radius gets that radius, not the global
    /// Ghostty config's.
    @Test(arguments: [12, 20, 1])
    func aFrostedThemePutsItsOwnRadiusOnTheWindow(radius: Int) {
        let (root, window, room, log) = makeWindow(Self.mocha(opacity: 0.85, blur: radius))
        #expect(root.backdrop.material == .frosted)
        #expect(log.radii.last == radius)
        window.close()
        withExtendedLifetime(room) {}
    }

    /// Frosted, then each other material: the radius ends at 0.
    @Test(arguments: [(0.85, 0, "see-through"), (0.85, -1, "regular glass"), (0.85, -2, "clear glass"), (1.0, 0, "opaque")])
    func leavingFrostedClearsTheRadius(opacity: Double, blur: Int, name: String) {
        let (root, window, room, log) = makeWindow(Self.mocha(opacity: 0.85, blur: 20))
        #expect(log.radii.last == 20)
        room.setOverride(ThemeSpec("Catppuccin Mocha")!, input: Self.mocha(opacity: opacity, blur: blur), animated: false)
        root.themeDidChange()
        #expect(root.backdrop.material != .frosted, "\(name)")
        #expect(log.radii.last == 0, "\(name) keeps a blur radius under it")
        window.close()
        withExtendedLifetime(room) {}
    }

    /// Glass and opaque windows never get a nonzero radius, from the start.
    @Test(arguments: [(0.85, -1), (1.0, -2), (1.0, 0), (1.0, 20)])
    func glassAndOpaqueNeverApplyABlur(opacity: Double, blur: Int) {
        let (_, window, room, log) = makeWindow(Self.mocha(opacity: opacity, blur: blur))
        #expect(!log.radii.isEmpty, "the radius is set to 0, not left as it was")
        #expect(log.radii.allSatisfy { $0 == 0 })
        window.close()
        withExtendedLifetime(room) {}
    }

    /// Glass or opaque, then frosted: the window takes the frosted radius.
    @Test(arguments: [(0.85, -1, "regular glass"), (0.85, -2, "clear glass"), (1.0, 0, "opaque")])
    func enteringFrostedAppliesItsRadius(opacity: Double, blur: Int, name: String) {
        let (root, window, room, log) = makeWindow(Self.mocha(opacity: opacity, blur: blur))
        #expect(root.backdrop.material != .frosted, "\(name)")
        #expect(log.radii.last == 0, "\(name)")
        room.setOverride(ThemeSpec("Catppuccin Mocha")!, input: Self.mocha(opacity: 0.85, blur: 20), animated: false)
        root.themeDidChange()
        #expect(root.backdrop.material == .frosted)
        #expect(log.radii.last == 20, "\(name) to frosted keeps the old radius")
        window.close()
        withExtendedLifetime(room) {}
    }

    /// A frosted theme whose radius changes moves the window to the new
    /// radius, not the old one.
    @Test(arguments: [(20, 8), (8, 20), (20, 1)])
    func changingTheFrostedRadiusMovesTheWindow(from: Int, to: Int) {
        let (root, window, room, log) = makeWindow(Self.mocha(opacity: 0.85, blur: from))
        #expect(log.radii.last == from)
        room.setOverride(ThemeSpec("Catppuccin Mocha")!, input: Self.mocha(opacity: 0.85, blur: to), animated: false)
        root.themeDidChange()
        #expect(root.backdrop.material == .frosted)
        #expect(log.radii.last == to)
        window.close()
        withExtendedLifetime(room) {}
    }

    /// Reduce Transparency makes a frosted config opaque: no blur either.
    @Test func reduceTransparencyClearsTheRadius() {
        let (_, window, room, log) = makeWindow(Self.mocha(opacity: 0.85, blur: 20), reduceTransparency: true)
        #expect(log.radii.allSatisfy { $0 == 0 })
        #expect(!log.radii.isEmpty, "the radius is cleared, not left as it was")
        window.close()
        withExtendedLifetime(room) {}
    }
}
