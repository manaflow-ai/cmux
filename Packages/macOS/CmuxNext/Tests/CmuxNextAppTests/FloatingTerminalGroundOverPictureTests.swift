import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import CmuxTheme
import GhosttyNextKit
import QuartzCore
import Testing

/// A floating pane's card with the default look (background opacity 1) is a solid surface. A terminal in it has
/// the terminal's own ground under its text, also when that ground is not the page background of the window's
/// theme (a terminal with a theme of its own) and also in a window with a background picture.
///
/// Over a picture the window is see-through, so a terminal's host paints as a tiled terminal does there: its own
/// theme's background at the window's tint, for the window's one sheet under it. In a card there is no sheet under
/// it: the card's opaque page background is. The two mix, and the terminal's text (made for its own background)
/// lies on a color that is neither.
@MainActor @Suite(.serialized, .closesItsWindows) struct FloatingTerminalGroundOverPictureTests {
    /// The window's theme (light) and the terminal's own theme (dark).
    static let page: UInt32 = 0xFFFFFF, own: UInt32 = 0x202228

    final class Panes: LayoutPaneContentProvider {
        let terminal: NSView
        init(terminal: NSView) { self.terminal = terminal }
        func makeContentView(for pane: PaneID) -> NSView { pane == "f" ? terminal : NSView() }
    }

    static let two = SplitNode.split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))

    static func scope(_ name: String, level: ThemeLevel, parent: ThemeScope? = nil, background: UInt32, foreground: UInt32) throws -> ThemeScope {
        let scope = parent.map { ThemeScope(level: level, parent: $0) } ?? ThemeScope(level: level)
        let grey = ThemeRGB(hex: 0x808080)
        let input = ThemeInput(background: ThemeRGB(hex: background), foreground: ThemeRGB(hex: foreground),
                               palette: Array(repeating: grey, count: 8))
        scope.setOverride(try #require(ThemeSpec(name)), input: input, animated: false)
        return scope
    }

    /// Straight-alpha sRGB `[r, g, b, a]` of a layer's color; no color is clear.
    static func rgba(_ color: CGColor?) -> [Double] {
        guard let color, let ns = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return [0, 0, 0, 0] }
        return [ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent].map { Double($0) }
    }

    /// `top` over `bottom`.
    static func over(_ top: [Double], _ bottom: [Double]) -> [Double] {
        let above: Double = top[3]
        let below: Double = bottom[3] * (1 - above)
        let alpha: Double = above + below
        guard alpha > 0 else { return [0, 0, 0, 0] }
        var mixed: [Double] = []
        for index in 0..<3 {
            let sum: Double = top[index] * above + bottom[index] * below
            mixed.append(sum / alpha)
        }
        mixed.append(alpha)
        return mixed
    }

    /// Each part of `a` is within `limit` of the same part of `b`.
    static func near(_ a: [Double], _ b: [Double], within limit: Double) -> Bool {
        guard a.count == b.count else { return false }
        for index in a.indices where abs(a[index] - b[index]) >= limit { return false }
        return true
    }

    /// The card's ground shape: the first layer of the card's surface, which is the card's last view.
    static func ground(of card: FloatingPaneCardView) throws -> CGColor {
        let surface = try #require(card.subviews.last?.layer, "SETUP: the card has no surface view")
        let shape = try #require(surface.sublayers?.first as? CAShapeLayer, "SETUP: the card's surface has no ground shape")
        return try #require(shape.fillColor, "SETUP: the card's ground has no color")
    }

    @Test(arguments: [false, true])
    func aFloatingTerminalWithItsOwnThemeHasItsOwnGroundUnderItsText(overAPicture: Bool) throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared // runs ghostty_init, which config_new needs
        let text = """
        background = #202228
        foreground = #f0f0f0

        """
        let config = try #require(ghostty_config_new())
        text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "cmux-next-test") }
        ghostty_config_finalize(config)
        let theme = GhosttyThemeConfig(config: config, themeName: "cmux-next-test",
                                       colors: GhosttyRuntime.themeColors(of: config, backgroundOpacity: 1))
        let want = Self.rgba(TerminalHostView.opaqueGround(theme))
        let dark: [Double] = [Double(0x20) / 255, Double(0x22) / 255, Double(0x28) / 255, 1]
        try #require(Self.near(want, dark, within: 0.01), "SETUP: the theme's ground is \(want)")

        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        defer { io.finish() }
        session.setTheme(theme)

        // The window's theme, with or without a picture, and the terminal's own theme inside it.
        let room = try Self.scope("Float Ground Light", level: .room, background: Self.page, foreground: 0x1F2328)
        if overAPicture { room.setBackdropSelection(.art(.vanGoghStarryNight)) }
        let terminal = try Self.scope("Float Ground Dark", level: .terminal, parent: room, background: Self.own, foreground: 0xF0F0F0)
        terminal.root(session.view)

        let provider = Panes(terminal: session.view)
        let floating = LayoutFloatingPane(pane: "f", frame: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.5))
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(Self.two), floating: [floating])],
                                activeScreenID: "s", focusedPane: "p1")
        model.splitSizingOverride = .even
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = true
        room.root(root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        for _ in 0..<600 where root.advanceFrame(1.0 / 120) {}

        let screen = try #require(root.screenViews["s"], "SETUP: the screen has no view")
        let card = try #require(screen.floatState.cards["f"], "SETUP: the floating pane has no card")
        try #require(!screen.floatState.look.isSeeThrough, "SETUP: the card's look is see-through; the default is not")
        // The product's own rule for "the window is see-through here": no ground for a terminal on the window's theme.
        try #require((TerminalHostView.ground(theme: nil, in: root) == nil) == overAPicture,
                     "SETUP: the window is \(overAPicture ? "not see-through over the picture" : "see-through with no picture")")
        // What each paints now, with the scopes above.
        card.updateLayer()
        session.view.paintGround()

        // What shows under the terminal's text: the card's ground and, over it, the ground of each view from the
        // pane's host down to the terminal's host.
        let cardGround = Self.rgba(try Self.ground(of: card))
        var chain: [NSView] = []
        var view: NSView? = session.view
        while let current = view, current !== screen {
            chain.append(current)
            view = current.superview
        }
        try #require(view === screen, "SETUP: the terminal's host is not in the screen's view")
        var shown = cardGround
        var grounds: [String] = []
        for view in chain.reversed() {
            let ground = Self.rgba(view.layer?.backgroundColor)
            if ground[3] > 0 { grounds.append("\(type(of: view)) \(ground)") }
            shown = Self.over(ground, shown)
        }

        #expect(cardGround[3] > 0.99, "the card is not solid with the default look: its ground is \(cardGround)")
        #expect(Self.near(shown, want, within: 0.02),
                """
                under the floating terminal's text the ground is \(shown), the terminal's own ground is \(want); \
                the card's ground is \(cardGround); the grounds over it: \(grounds); \
                the window's shown opacity is \(room.shownWindowOpacity)
                """)
    }
}
