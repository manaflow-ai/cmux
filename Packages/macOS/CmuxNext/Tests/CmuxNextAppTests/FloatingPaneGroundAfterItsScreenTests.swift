import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import CmuxTheme
import GhosttyNextKit
import QuartzCore
import Testing

/// With a see-through look (the Debug Settings knob `Background opacity` below 1), a floating pane's card paints
/// the pane's one ground and the views inside the pane paint none: the pane's clip says so (`ownsContentGround`).
/// A pane that does not float any more has no card, so its views paint their own ground again. That holds when
/// the pane becomes a tiled pane of its screen, and when its screen goes and another screen shows the pane.
@MainActor @Suite(.serialized, .closesItsWindows) struct FloatingPaneGroundAfterItsScreenTests {
    /// The window's theme (light) and the terminal's own theme (dark).
    static let page: UInt32 = 0xFFFFFF, own: UInt32 = 0x202228

    final class Panes: LayoutPaneContentProvider {
        let terminal: NSView
        init(terminal: NSView) { self.terminal = terminal }
        func makeContentView(for pane: PaneID) -> NSView { pane == "f" ? terminal : NSView() }
    }

    static let two = SplitNode.split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
    /// The pane "f" as a tiled pane beside the two.
    static let three = SplitNode.split("g", axis: .horizontal, ratio: 0.34, a: .leaf("f"), b: two)

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

    @Test(arguments: [false, true])
    func aPaneThatDoesNotFloatAnyMorePaintsItsOwnGround(itsScreenGoes: Bool) throws {
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

        // The see-through look. The store takes only registered keys; the knob goes back after the test.
        let knob = FloatingPaneTunables.backgroundOpacity.key
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(FloatingPaneTunables.all)
        defer { TunableStore.shared.set(knob, nil) }
        try #require(TunableStore.shared.set(knob, .number(0.6)) != nil, "SETUP: the store refused \(knob)")

        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        defer { io.finish() }
        session.setTheme(theme)

        // An opaque window with a light theme, and the terminal's own dark theme inside it.
        let room = try Self.scope("Float Screen Light", level: .room, background: Self.page, foreground: 0x1F2328)
        let terminal = try Self.scope("Float Screen Dark", level: .terminal, parent: room, background: Self.own, foreground: 0xF0F0F0)
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

        // The start: the pane floats, its card paints its ground, the terminal paints none.
        let first = try #require(root.screenViews["s"], "SETUP: the screen has no view")
        try #require(first.floatState.cards["f"] != nil, "SETUP: the floating pane has no card")
        try #require(first.floatState.look.isSeeThrough, "SETUP: the card's look is not see-through with the knob at 0.6")
        try #require(TerminalHostView.ground(theme: nil, in: root) != nil, "SETUP: the window is see-through; it has no picture")
        let host = try #require(root.context.hosts["f"], "SETUP: the floating pane has no host")
        try #require(host.superview === first, "SETUP: the floating pane's host is not in its screen's view")
        try #require(host.clipView.ownsContentGround, "SETUP: the see-through card does not own the pane's ground")
        session.view.paintGround()
        try #require(session.view.layer?.backgroundColor == nil, "SETUP: the terminal paints a ground under the see-through card")

        // The pane does not float any more: it is a tiled pane of its screen, or of the screen that replaces that one.
        let id: ScreenID = itsScreenGoes ? "t" : "s"
        model.apply(screens: [LayoutScreen(id: id, name: itsScreenGoes ? "t" : "s", layout: .splits(Self.three), floating: [])])
        root.syncWithModel()
        for _ in 0..<600 where root.advanceFrame(1.0 / 120) {}

        let screen = try #require(root.screenViews[id], "SETUP: the pane's screen has no view")
        try #require(root.screenViews.count == 1, "SETUP: \(root.screenViews.count) screens have a view")
        try #require(screen.floatState.cards.isEmpty, "SETUP: a card is left in the pane's screen")
        try #require(root.context.hosts["f"] === host, "SETUP: the pane has another host")
        try #require(host.superview === screen, "SETUP: the pane's host is not in its screen's view")
        // What the terminal paints now, with the mark that its pane's clip has now.
        session.view.paintGround()

        // What shows under the terminal's text: the window's page color and, over it, the ground of each view from
        // the pane's host down to the terminal's host.
        var chain: [NSView] = []
        var view: NSView? = session.view
        while let current = view, current !== screen {
            chain.append(current)
            view = current.superview
        }
        try #require(view === screen, "SETUP: the terminal's host is not in the screen's view")
        var shown: [Double] = [1, 1, 1, 1]
        var grounds: [String] = []
        for view in chain.reversed() {
            let ground = Self.rgba(view.layer?.backgroundColor)
            if ground[3] > 0 { grounds.append("\(type(of: view)) \(ground)") }
            shown = Self.over(ground, shown)
        }

        #expect(!host.clipView.ownsContentGround, "the pane's clip still says that a card paints the pane's ground; the pane has no card")
        #expect(Self.near(shown, want, within: 0.02),
                """
                under the tiled terminal's text the ground is \(shown), the terminal's own ground is \(want); \
                the grounds over the window's page color: \(grounds)
                """)
    }
}
