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
            // What AppKit's titlebar tiling does in each case above: it sets the buttons back at its place itself.
            ("AppKit's tiling moves the close button", { close.map { $0.setFrameOrigin(NSPoint(x: 7, y: $0.frame.minY + 1.25)) } }),
            ("AppKit's tiling moves the zoom button", {
                window.standardWindowButton(.zoomButton).map { $0.setFrameOrigin(NSPoint(x: $0.frame.minX - 1.25, y: $0.frame.minY + 1.25)) }
            }),
            ("AppKit's tiling resets the container", {
                container.map { $0.setFrameSize(NSSize(width: $0.frame.width, height: window.frame.height - window.contentLayoutRect.maxY)) }
            }),
        ]
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
