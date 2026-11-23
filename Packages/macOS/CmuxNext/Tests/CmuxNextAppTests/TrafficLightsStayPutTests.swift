import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The user, 2026-11-19 (msg 42216): "traffic light shifts around which is very bad; fix from first principles, fix root
/// cause". His recording (nightly 34acb49): each time he left Home for a workspace the lights went back to macOS's
/// place, 16 pt below the window's top, and stayed there about 1.2 s; then they jumped down and right by 1.25 pt onto the
/// top row's line. AppKit lays its own titlebar out again on its own (a new window title, an appearance or key change,
/// a titlebar layout) and puts the lights at its place; the root view put them back only at its next layout.
/// One owner per window (`TrafficLightsOwner`) puts every button back in the same call and once more before the frame
/// commits, so from frame to frame they never move. What counts is what the next frame shows: each event runs, then one
/// pass of the main run loop through its before-waiting stage (AppKit's display cycle, then Core Animation's commit).
/// What the buttons' frames say right after the event, before that pass, is printed (`DRIFT_SYNC`), not held.
@MainActor @Suite(.serialized, .closesItsWindows) struct TrafficLightsStayPutTests {
    private func window() -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        for _ in 0..<2 {
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
        }
        return (window, root)
    }

    /// The three buttons' frames in the window, in order: what the user sees move.
    private func lights(_ window: NSWindow) -> [CGRect] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type in
            window.standardWindowButton(type).map { $0.convert($0.bounds, to: nil) }
        }
    }

    /// Things AppKit does to the titlebar on its own, none of which lays out the root view. Each runs, then the lights
    /// are read with no layout of ours in between: what the next frame on screen draws.
    private func appKitTitlebarEvents(_ window: NSWindow) -> [(String, () -> Void)] {
        let close = window.standardWindowButton(.closeButton)
        let titlebar = close?.superview, container = titlebar?.superview
        let native = Self.nativeOrigins(like: window, in: titlebar)
        return [
            ("a new window title (Home to a workspace)", { window.title = "cmux perf lead" }),
            ("another title", { window.title = "Home" }),
            ("a subtitle", { window.subtitle = "3 tabs" }),
            ("title hidden", { window.titleVisibility = .hidden }),
            ("title shown", { window.titleVisibility = .visible }),
            ("dark appearance", { window.appearance = NSAppearance(named: .darkAqua) }),
            ("light appearance", { window.appearance = NSAppearance(named: .aqua) }),
            ("the titlebar's own layout", {
                titlebar?.needsLayout = true
                container?.needsLayout = true
                container?.layoutSubtreeIfNeeded()
            }),
            ("a display pass", { window.displayIfNeeded() }),
            // What AppKit's titlebar tiling does in each case above: it sets each button at its own place again (a bare
            // window's frame for it, in the titlebar view), the titlebar view's bounds back to zero, the container to its height.
            ("AppKit tiles the close button at its place", { native[.closeButton].map { close?.setFrameOrigin($0) } }),
            ("AppKit tiles the zoom button at its place", {
                native[.zoomButton].map { window.standardWindowButton(.zoomButton)?.setFrameOrigin($0) }
            }),
            ("AppKit tiles every button at its place", {
                for (type, origin) in native { window.standardWindowButton(type)?.setFrameOrigin(origin) }
            }),
            ("AppKit tiles every button 2 pt lower (another titlebar height)", {
                for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    window.standardWindowButton(type).map { $0.setFrameOrigin(NSPoint(x: $0.frame.minX, y: $0.frame.minY - 2)) }
                }
            }),
            ("AppKit resets the titlebar view's bounds", { titlebar?.setBoundsOrigin(.zero) }),
            ("AppKit resets the container", {
                container.map { $0.setFrameSize(NSSize(width: $0.frame.width, height: window.frame.height - window.contentLayoutRect.maxY)) }
            }),
        ]
    }

    /// Where AppKit puts each light in `titlebar`: as far from its left and top edges as in a bare window of the same
    /// style, which nothing moved (the titlebar view here may be taller).
    private static func nativeOrigins(like window: NSWindow, in titlebar: NSView?) -> [NSWindow.ButtonType: CGPoint] {
        let bare = NSWindow(contentRect: window.contentRect(forFrameRect: window.frame), styleMask: window.styleMask,
                            backing: .buffered, defer: false)
        bare.isReleasedWhenClosed = false
        bare.titlebarAppearsTransparent = window.titlebarAppearsTransparent
        defer { bare.close() }
        var out: [NSWindow.ButtonType: CGPoint] = [:]
        guard let titlebar else { return out }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = bare.standardWindowButton(type), let own = button.superview else { continue }
            let top = own.isFlipped ? button.frame.minY : own.frame.height - button.frame.maxY
            out[type] = CGPoint(x: button.frame.minX, y: titlebar.isFlipped ? top : titlebar.frame.height - top - button.frame.height)
        }
        return out
    }

    @Test(arguments: DensityPreset.allCases)
    func theLightsNeverMoveFromFrameToFrame(density: DensityPreset) throws {
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.titlebar, design.tabBarPosition)
        defer { (design.densityTokens, design.titlebar, design.tabBarPosition) = saved }
        design.densityTokens = density.tokens
        design.titlebar = .minimal
        design.tabBarPosition = .top
        let (window, _) = window()
        defer { window.close() }
        let line = try #require(WindowTitlebar.topRowLine(in: window), "\(density): no top row line")
        let rest = lights(window)
        try #require(rest.count == 3, "\(density): \(rest.count) traffic lights")
        let center = window.frame.height - rest[0].midY
        #expect(abs(center - line.centerY) <= 0.5, "\(density): the lights rest at \(center), the line at \(line.centerY)")
        let spacing = Self.nativeOrigins(like: window, in: window.standardWindowButton(.closeButton)?.superview)
        let close = spacing[.closeButton]?.x ?? 0
        #expect(TrafficLightsOwner.nativeOffsets(for: window.styleMask) == spacing.mapValues { $0.x - close },
                "\(density): the owner's spacing is not macOS's own")
        var drift: CGFloat = 0
        for (event, run) in appKitTitlebarEvents(window) {
            run()
            print("DRIFT_SYNC|\(density.rawValue)|\(event)|\(Self.moved(rest, lights(window)))")
            Self.nextFrame()
            let now = lights(window)
            let moved = Self.moved(rest, now)
            drift = max(drift, moved)
            print("DRIFT|\(density.rawValue)|\(event)|\(moved)")
            #expect(now == rest, "\(density): after \(event) the next frame shows the lights moved by \(moved) pt: \(now), at rest \(rest)")
        }
        print("DRIFT|\(density.rawValue)|max|\(drift)")
    }

    /// A live resize of the window: each step AppKit moves the lights' container with the window's top edge and widens
    /// it, and the owner places nothing while every light is still where it put them (`TrafficLightsOwner.Rest`). That
    /// guard must never keep a light off the line: through the steps they stay put from the window's top-left corner,
    /// and a light AppKit moves with the window resized still goes back.
    @Test func theLightsStayPutThroughALiveResize() throws {
        let design = DesignSettings.shared
        let saved = (design.titlebar, design.tabBarPosition)
        defer { (design.titlebar, design.tabBarPosition) = saved }
        design.titlebar = .minimal
        design.tabBarPosition = .top
        let (window, root) = window()
        defer { window.close() }
        func fromTop() -> [CGPoint] { lights(window).map { CGPoint(x: $0.minX, y: window.frame.height - $0.maxY) } }
        let rest = fromTop()
        try #require(rest.count == 3, "\(rest.count) traffic lights")
        let start = window.frame
        for step in 1...6 {
            let size = NSSize(width: start.width + CGFloat(step * 37), height: start.height - CGFloat(step * 23))
            window.setFrame(NSRect(origin: start.origin, size: size), display: false)
            Self.nextFrame()
            #expect(fromTop() == rest, "resize step \(step): the next frame shows the lights at \(fromTop()), at rest \(rest)")
            root.layoutSubtreeIfNeeded()
            #expect(fromTop() == rest, "resize step \(step): after the root's layout the lights sit at \(fromTop()), at rest \(rest)")
        }
        let zoom = try #require(window.standardWindowButton(.zoomButton))
        zoom.setFrameOrigin(NSPoint(x: zoom.frame.minX + 3, y: zoom.frame.minY - 2))
        Self.nextFrame()
        #expect(fromTop() == rest, "a light AppKit moved after the resize stays at \(fromTop()), at rest \(rest)")
    }

    private static func moved(_ rest: [CGRect], _ now: [CGRect]) -> CGFloat {
        zip(rest, now).map { max(abs($0.minX - $1.minX), abs($0.minY - $1.minY)) }.max() ?? .infinity
    }

    /// The next frame: one pass of the main run loop through its before-waiting stage, where AppKit's display cycle and
    /// Core Animation's commit run (a timer keeps the pass from ending before it waits).
    static func nextFrame() {
        RunLoop.current.add(Timer(timeInterval: 0.01, repeats: false) { _ in }, forMode: .default)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }
}
