import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextHome
import CmuxNextTestSupport
import Foundation
import Testing

/// The user, 2026-11-19 (msg 42221): "more than traffic lights btw, stuff in the home imessage chief ui shifts around too".
/// Home's list header lays its search row out under the traffic lights (`HomeSidebarHeaderLayout`, Messages' look) and
/// re-reads them at every layout, so each time AppKit put the lights back at its own place (a new window title, an
/// appearance change, its titlebar's layout) the search field, the filter button and the list under them moved with
/// them: 3 px in his recording. With one owner of the lights (`TrafficLightsOwner`) the lights stay on the top row's line,
/// and so does everything Home lays out from them.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeHeaderStaysPutTests {
    @Test(arguments: [DensityPreset.compact, .spacious])
    func homesHeaderNeverMovesFromFrameToFrame(density: DensityPreset) throws {
        _ = NSApplication.shared
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.titlebar, design.tabBarPosition)
        defer { (design.densityTokens, design.titlebar, design.tabBarPosition) = saved }
        design.densityTokens = density.tokens
        design.titlebar = .minimal
        design.tabBarPosition = .top
        let suite = "cmux.tests.homeHeaderStaysPut.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 800))
        let chat = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 800))
        let split = HomeSidebarSplitView(sidebar: home, content: chat, widths: HomeSidebarWidth(defaults: defaults))
        split.showsList = true // the person showed the list (folded by default: ChiefReplacesHomeTests)
        split.windowKey = { "w" }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        defer { window.close() }
        window.contentView = split
        split.setWidth(320)
        // As the root view's layout does: the lights on the top row's line, then Home lays out under them.
        TrafficLightsLine.apply(in: window)
        settle(home, split)
        let rest = frames(window, home)
        try #require(rest["search"].map { !$0.isEmpty } == true, "\(density): no search field: \(rest)")
        try #require(rest["lights"].map { $0.maxY > 0 } == true, "\(density): no traffic lights")
        let titlebar = window.standardWindowButton(.closeButton)?.superview
        let events: [(String, () -> Void)] = [
            ("a new window title (Home to a workspace)", { window.title = "cmux perf lead" }),
            ("another title", { window.title = "Home" }),
            ("dark appearance", { window.appearance = NSAppearance(named: .darkAqua) }),
            ("the titlebar's own layout", {
                titlebar?.superview?.needsLayout = true
                titlebar?.superview?.layoutSubtreeIfNeeded()
            }),
            ("AppKit tiles every button 2 pt lower (another titlebar height)", {
                for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    window.standardWindowButton(type).map { $0.setFrameOrigin(NSPoint(x: $0.frame.minX, y: $0.frame.minY - 2)) }
                }
            }),
            ("AppKit resets the titlebar view's bounds", { titlebar?.setBoundsOrigin(.zero) }),
        ]
        var drift: CGFloat = 0
        for (event, run) in events {
            run()
            // The next frame, then the next layout of Home (any layout pass re-reads the lights).
            TrafficLightsStayPutTests.nextFrame()
            settle(home, split)
            let now = frames(window, home)
            for (name, frame) in rest.sorted(by: { $0.key < $1.key }) {
                let moved = now[name].map { max(abs($0.minX - frame.minX), abs($0.minY - frame.minY)) } ?? .infinity
                drift = max(drift, moved)
                print("HOME_DRIFT|\(density.rawValue)|\(event)|\(name)|\(moved)")
                #expect(moved == 0, "\(density): after \(event) Home's \(name) moved by \(moved) pt: \(String(describing: now[name])), at rest \(frame)")
            }
        }
        print("HOME_DRIFT|\(density.rawValue)|max|\(drift)")
    }

    /// A new window title and a layout of Home with no frame between them (a stray `CFRunLoopStop` from another test
    /// cut `nextFrame()` short so, in the full Home run where `homesHeaderNeverMovesFromFrameToFrame` failed by 4 pt at
    /// Spacious). AppKit re-tiles the miniaturize and zoom buttons after a new title and the owner puts them back only
    /// at the next run loop pass, so for that moment the three buttons' frames are neither place: their union was
    /// 51 x 23 pt, not 60 x 14, its middle 4.5 pt higher. Home laid its header out on that box and kept it until its
    /// next layout. Home's header follows the line the lights are kept on, not the buttons' frames of the moment.
    @Test(arguments: [DensityPreset.compact, .spacious])
    func aNewTitleWithNoFrameBetweenLeavesTheHeaderWhereItWas(density: DensityPreset) throws {
        _ = NSApplication.shared
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.titlebar, design.tabBarPosition)
        defer { (design.densityTokens, design.titlebar, design.tabBarPosition) = saved }
        design.densityTokens = density.tokens
        design.titlebar = .minimal
        design.tabBarPosition = .top
        let suite = "cmux.tests.homeHeaderNoFrame.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 800))
        let split = HomeSidebarSplitView(sidebar: home, content: NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 800)),
                                         widths: HomeSidebarWidth(defaults: defaults))
        split.windowKey = { "w" }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        defer { window.close() }
        window.contentView = split
        split.setWidth(320)
        TrafficLightsLine.apply(in: window)
        settle(home, split)
        let rest = home.header
        for title in ["cmux perf lead", "Home", "a much longer workspace title than the others"] {
            window.title = title
            // No frame: Home lays out in the same run loop pass as the new title.
            settle(home, split)
            print("HOME_NO_FRAME|\(density.rawValue)|\(title)|filter=\(home.header.filter)|listTop=\(home.header.listTop)|rest=\(rest.filter)")
            #expect(home.header == rest, "\(density): a new title (\(title)) moved Home's header: filter \(rest.filter) -> \(home.header.filter), list top \(rest.listTop) -> \(home.header.listTop)")
        }
    }

    private func settle(_ home: HomeSidebarView, _ split: NSView) {
        home.updateWindowControlsAvoidance()
        split.needsLayout = true
        split.layoutSubtreeIfNeeded()
        home.list.headerView.needsLayout = true
        home.list.headerView.layoutSubtreeIfNeeded()
    }

    /// What the user sees in Home's top: the lights, the search field and the header's other views, in the window.
    private func frames(_ window: NSWindow, _ home: HomeSidebarView) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        out["lights"] = WindowTitlebar.trafficLightsFrame(in: window) ?? .zero
        let field = home.list.searchField
        out["search"] = field.convert(field.bounds, to: nil)
        for (index, view) in home.list.headerView.subviews.enumerated() where !view.isHidden && !view.frame.isEmpty {
            out["header view \(index) \(type(of: view))"] = view.convert(view.bounds, to: nil)
        }
        return out
    }
}
