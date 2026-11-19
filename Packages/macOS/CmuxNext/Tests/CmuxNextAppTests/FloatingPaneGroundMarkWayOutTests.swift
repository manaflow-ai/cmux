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

/// A floating pane's card puts one of 2 marks on its pane's clip: with a see-through look the card paints the
/// pane's one ground and the views inside paint none (`ownsContentGround`); with a solid look the card's opaque
/// ground is under the pane (`hasSolidGroundUnder`). A mark is true only while that card is under the pane, and a
/// terminal's host paints again at each change of a mark. These tests hold the ways out of the marks.
@MainActor @Suite(.serialized, .closesItsWindows) struct FloatingPaneGroundMarkWayOutTests {
    typealias Ground = FloatingTerminalGroundOverPictureTests

    /// The pane "f" as a tiled pane beside the two.
    static let three = SplitNode.split("g", axis: .horizontal, ratio: 0.34, a: .leaf("f"), b: Ground.two)

    /// The screen "s" in a light window of 1200 by 800: 2 tiled panes and the floating pane "f", a terminal with a
    /// dark theme of its own. No motion; the test is the clock.
    @MainActor final class Scene {
        let io: ScriptedTerminalIO
        let session: TerminalSession
        let provider: Ground.Panes
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        /// The terminal's own ground, opaque.
        let want: [Double]

        init(overAPicture: Bool) throws {
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
            let own = Ground.rgba(TerminalHostView.opaqueGround(theme))
            let dark: [Double] = [Double(0x20) / 255, Double(0x22) / 255, Double(0x28) / 255, 1]
            try #require(Ground.near(own, dark, within: 0.01), "SETUP: the theme's ground is \(own)")

            let scripted = ScriptedTerminalIO()
            let terminalSession = TerminalSession(io: scripted)
            try #require(terminalSession.surfaceView.surface != nil, "libghostty created no surface")
            terminalSession.setTheme(theme)

            // The window's theme, with or without a picture, and the terminal's own theme inside it.
            let room = try Ground.scope("Float Way Out Light", level: .room, background: Ground.page, foreground: 0x1F2328)
            if overAPicture { room.setBackdropSelection(.art(.vanGoghStarryNight)) }
            let terminal = try Ground.scope("Float Way Out Dark", level: .terminal, parent: room, background: Ground.own, foreground: 0xF0F0F0)
            terminal.root(terminalSession.view)

            let panes = Ground.Panes(terminal: terminalSession.view)
            let floating = LayoutFloatingPane(pane: "f", frame: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.5))
            let layout = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(Ground.two), floating: [floating])],
                                     activeScreenID: "s", focusedPane: "p1")
            layout.splitSizingOverride = .even
            let view = LayoutRootView(model: layout, contentProvider: panes)
            view.context.reduceMotionOverride = true
            room.root(view)
            let frame = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                                 backing: .buffered, defer: true)
            frame.contentView = view
            view.layoutSubtreeIfNeeded()
            view.driver.isManual = true
            io = scripted
            session = terminalSession
            provider = panes
            model = layout
            root = view
            window = frame
            want = own
            settle()
        }

        func settle() {
            for _ in 0..<600 where root.advanceFrame(1.0 / 120) {}
        }

        func finish() {
            io.finish()
            window.closeAfterTest()
        }

        /// What the terminal's host paints under its text now.
        var terminalGround: [Double] { Ground.rgba(session.view.layer?.backgroundColor) }

        /// What shows under the terminal's text in `screen`: `bottom` and, over it, the ground of each view from the
        /// pane's host down to the terminal's host. `grounds` names each ground that is not clear.
        func shownUnderText(in screen: NSView, over bottom: [Double]) throws -> (shown: [Double], grounds: [String]) {
            var chain: [NSView] = []
            var view: NSView? = session.view
            while let current = view, current !== screen {
                chain.append(current)
                view = current.superview
            }
            try #require(view === screen, "SETUP: the terminal's host is not in the screen's view")
            var shown = bottom
            var grounds: [String] = []
            for view in chain.reversed() {
                let ground = Ground.rgba(view.layer?.backgroundColor)
                if ground[3] > 0 { grounds.append("\(type(of: view)) \(ground)") }
                shown = Ground.over(ground, shown)
            }
            return (shown, grounds)
        }
    }

    /// The pane's host goes from one screen's view to another's, and the second screen's card puts its mark on the
    /// pane's clip. The first screen's card, which lost the pane, then ends its own state: it does not take the
    /// second card's mark away. Each mark: the solid look's and the see-through look's.
    @Test(arguments: [false, true])
    func theCardThatLostItsPaneLeavesTheNextCardsMark(seeThrough: Bool) throws {
        _ = NSApplication.shared
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let second = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let firstCard = FloatingPaneCardView(pane: "f"), secondCard = FloatingPaneCardView(pane: "f")
        // The pane's content: a view whose ground is its layer's color (`NSView.paneGroundColor`).
        let content = NSView()
        content.layer = CALayer()
        content.wantsLayer = true
        let host = PaneHostView(pane: "f", content: content)
        first.addSubview(firstCard)
        first.addSubview(host)
        second.addSubview(secondCard)
        let clip = host.clipView
        firstCard.paintGround(of: host, seeThrough: seeThrough)
        try #require(seeThrough ? clip.ownsContentGround : clip.hasSolidGroundUnder, "SETUP: the first screen's card put no mark on the pane's clip")

        // The second screen takes the pane's host and its card's pass runs; then the first screen's pass ends its card.
        second.addSubview(host)
        secondCard.paintGround(of: host, seeThrough: seeThrough)
        try #require(seeThrough ? clip.ownsContentGround : clip.hasSolidGroundUnder, "SETUP: the second screen's card put no mark on the pane's clip")
        firstCard.paintGround(of: nil, seeThrough: false)

        #expect(seeThrough ? clip.ownsContentGround : clip.hasSolidGroundUnder,
                "the card of the screen that lost the pane took the mark of the pane's card in the other screen away")
        if seeThrough {
            #expect(clip.onContentGroundChange != nil, "the pane's card in the other screen does not hear a change of the pane's ground any more")
            // Whose callback it is: the pane's content gets a new ground, and the second screen's card must have it.
            let ground: [Double] = [0.2, 0.4, 0.6, 1]
            content.layer?.backgroundColor = CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
            try #require(Ground.near(Ground.rgba(content.paneGroundColor), ground, within: 0.01), "SETUP: the content's ground is \(Ground.rgba(content.paneGroundColor))")
            clip.contentGroundDidChange()
            let heard = Ground.rgba(secondCard.contentGround)
            #expect(Ground.near(heard, ground, within: 0.01),
                    "the pane's content has the new ground \(ground); the card of the screen that has the pane now paints \(heard)")
        }
    }

    /// With the solid look (the default) in a window with a background picture, the card's opaque ground is under a
    /// floating terminal, and the terminal paints its own background opaque. A pane that does not float any more
    /// has no card under it: its clip does not say so any more, and the terminal paints its background at the
    /// window's tint again (a tiled terminal's rule). Through the layout, with no paint by hand: when the pane
    /// becomes a tiled pane of its screen, and when its screen goes and another screen shows the pane.
    @Test(arguments: [false, true])
    func aPaneThatDoesNotFloatAnyMoreOverAPictureHasNoSolidGroundUnderIt(itsScreenGoes: Bool) throws {
        let scene = try Scene(overAPicture: true)
        defer { scene.finish() }
        let first = try #require(scene.root.screenViews["s"], "SETUP: the screen has no view")
        try #require(first.floatState.cards["f"] != nil, "SETUP: the floating pane has no card")
        try #require(!first.floatState.look.isSeeThrough, "SETUP: the card's look is see-through; the default is not")
        try #require(TerminalHostView.ground(theme: nil, in: scene.root) == nil, "SETUP: the window is not see-through over the picture")
        let host = try #require(scene.root.context.hosts["f"], "SETUP: the floating pane has no host")
        try #require(host.superview === first, "SETUP: the floating pane's host is not in its screen's view")
        try #require(host.clipView.hasSolidGroundUnder, "SETUP: the solid card put no mark on the pane's clip")
        let start = scene.terminalGround
        try #require(Ground.near(start, scene.want, within: 0.02),
                     "SETUP: under the solid card the terminal's ground is \(start), its own ground is \(scene.want)")

        // The pane does not float any more: it is a tiled pane of its screen, or of the screen that replaces that one.
        let id: ScreenID = itsScreenGoes ? "t" : "s"
        scene.model.apply(screens: [LayoutScreen(id: id, name: "s", layout: .splits(Self.three), floating: [])])
        scene.root.syncWithModel()
        scene.settle()

        let screen = try #require(scene.root.screenViews[id], "SETUP: the pane's screen has no view")
        try #require(scene.root.screenViews.count == 1, "SETUP: \(scene.root.screenViews.count) screens have a view")
        try #require(screen.floatState.cards.isEmpty, "SETUP: a card is left in the pane's screen")
        try #require(scene.root.context.hosts["f"] === host, "SETUP: the pane has another host")
        try #require(host.superview === screen, "SETUP: the pane's host is not in its screen's view")

        let tiled = scene.terminalGround
        #expect(!host.clipView.hasSolidGroundUnder, "the pane's clip still says that a card's opaque ground is under the pane; the pane has no card")
        #expect(tiled[3] > 0.05 && tiled[3] < 0.99,
                "with no card under it the terminal's ground is \(tiled); a tiled terminal over a picture has its own ground at the window's tint")
    }

    /// With a see-through look (the Debug Settings knob `Background opacity` below 1) the views inside a floating
    /// pane paint no ground. A pane that does not float any more has no card, so its views paint their own ground
    /// again: when the pane becomes a tiled pane of its screen, and when its screen goes and another screen shows
    /// the pane. No paint by hand: each ground is what the terminal's host painted when its pane's mark changed.
    @Test(arguments: [false, true])
    func aPaneThatDoesNotFloatAnyMorePaintsItsOwnGround(itsScreenGoes: Bool) throws {
        // The see-through look. The store takes only registered keys; the knob goes back after the test.
        let knob = FloatingPaneTunables.backgroundOpacity.key
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(FloatingPaneTunables.all)
        defer { TunableStore.shared.set(knob, nil) }
        try #require(TunableStore.shared.set(knob, .number(0.6)) != nil, "SETUP: the store refused \(knob)")

        // An opaque window: a terminal with its own theme paints its own ground opaque there.
        let scene = try Scene(overAPicture: false)
        defer { scene.finish() }
        let first = try #require(scene.root.screenViews["s"], "SETUP: the screen has no view")
        try #require(first.floatState.cards["f"] != nil, "SETUP: the floating pane has no card")
        try #require(first.floatState.look.isSeeThrough, "SETUP: the card's look is not see-through with the knob at 0.6")
        try #require(TerminalHostView.ground(theme: nil, in: scene.root) != nil, "SETUP: the window is see-through; it has no picture")
        let host = try #require(scene.root.context.hosts["f"], "SETUP: the floating pane has no host")
        try #require(host.superview === first, "SETUP: the floating pane's host is not in its screen's view")
        try #require(host.clipView.ownsContentGround, "SETUP: the see-through card does not own the pane's ground")
        try #require(scene.session.view.layer?.backgroundColor == nil,
                     "SETUP: the terminal paints the ground \(scene.terminalGround) under the see-through card")

        // The pane does not float any more: it is a tiled pane of its screen, or of the screen that replaces that one.
        let id: ScreenID = itsScreenGoes ? "t" : "s"
        scene.model.apply(screens: [LayoutScreen(id: id, name: "s", layout: .splits(Self.three), floating: [])])
        scene.root.syncWithModel()
        scene.settle()

        let screen = try #require(scene.root.screenViews[id], "SETUP: the pane's screen has no view")
        try #require(scene.root.screenViews.count == 1, "SETUP: \(scene.root.screenViews.count) screens have a view")
        try #require(screen.floatState.cards.isEmpty, "SETUP: a card is left in the pane's screen")
        try #require(scene.root.context.hosts["f"] === host, "SETUP: the pane has another host")
        try #require(host.superview === screen, "SETUP: the pane's host is not in its screen's view")

        let under = try scene.shownUnderText(in: screen, over: [1, 1, 1, 1])
        #expect(!host.clipView.ownsContentGround, "the pane's clip still says that a card paints the pane's ground; the pane has no card")
        #expect(Ground.near(under.shown, scene.want, within: 0.02),
                """
                under the tiled terminal's text the ground is \(under.shown), the terminal's own ground is \(scene.want); \
                the grounds over the window's page color: \(under.grounds)
                """)
    }

    /// In a window with a background picture, a floating terminal with its own theme paints again at each change
    /// of its card's marks, with no paint by hand: opaque under the solid card that the layout's pass made, at the
    /// window's tint when the card ends (a tiled terminal's rule), no ground under a see-through card, and opaque
    /// again under a solid card.
    @Test func aFloatingTerminalPaintsAgainAtEachChangeOfItsCardsMarks() throws {
        let scene = try Scene(overAPicture: true)
        defer { scene.finish() }
        let screen = try #require(scene.root.screenViews["s"], "SETUP: the screen has no view")
        let card = try #require(screen.floatState.cards["f"], "SETUP: the floating pane has no card")
        let host = try #require(scene.root.context.hosts["f"], "SETUP: the floating pane has no host")
        try #require(!screen.floatState.look.isSeeThrough, "SETUP: the card's look is see-through; the default is not")
        try #require(TerminalHostView.ground(theme: nil, in: scene.root) == nil, "SETUP: the window is not see-through over the picture")
        try #require(host.clipView.hasSolidGroundUnder, "SETUP: the solid card put no mark on the pane's clip")

        let start = scene.terminalGround
        #expect(Ground.near(start, scene.want, within: 0.02),
                "under the solid card of the layout's pass the terminal's ground is \(start), its own ground is \(scene.want)")

        // The pane stops to float: the card ends its state, as the layout's pass does before it removes the card.
        card.paintGround(of: nil, seeThrough: false)
        let tiled = scene.terminalGround
        #expect(tiled[3] > 0.05 && tiled[3] < 0.99,
                "with no card under it the terminal's ground is \(tiled); a tiled terminal over a picture has its own ground at the window's tint")

        // The look becomes see-through: the card paints the pane's one ground.
        card.paintGround(of: host, seeThrough: true)
        #expect(scene.session.view.layer?.backgroundColor == nil,
                "under a see-through card the terminal paints the ground \(scene.terminalGround); the card paints the pane's one ground")

        // The look is solid again.
        card.paintGround(of: host, seeThrough: false)
        let solid = scene.terminalGround
        #expect(Ground.near(solid, scene.want, within: 0.02),
                "under the card that is solid again the terminal's ground is \(solid), its own ground is \(scene.want)")
    }
}
