import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextHome
import CmuxNextTestSupport
import Foundation
import Testing

/// The user, 2026-11-19 (msg 42221): "more than traffic lights btw, stuff in the home imessage chief ui shifts around
/// too". His recording (CleanShot 2026-11-19 at 8.19.06 PM): each time the window's sidebar showed or hid over Home, Home's
/// search field, its avatars and every row of its list jumped about 28 pt up or down. Home's list had two headers: under
/// the traffic lights (the window's sidebar hidden) the lights took the top row and the search field the row under them;
/// clear of the lights (the sidebar shown beside Home) the search field took the top row. A sidebar toggle moves Home
/// sideways only: what Home lays out keeps its height in the window, lights over it or not.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeListStaysPutOnSidebarToggleTests {
    @Test(arguments: [DensityPreset.compact, .spacious])
    func homesListKeepsItsLineWhenTheSidebarToggles(density: DensityPreset) throws {
        _ = NSApplication.shared
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.titlebar, design.tabBarPosition)
        defer { (design.densityTokens, design.titlebar, design.tabBarPosition) = saved }
        design.densityTokens = density.tokens
        design.titlebar = .minimal
        design.tabBarPosition = .top
        let suite = "cmux.tests.homeListStaysPut.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 800))
        let chat = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 800))
        let split = HomeSidebarSplitView(sidebar: home, content: chat, widths: HomeSidebarWidth(defaults: defaults))
        split.windowKey = { "w" }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        defer { window.close() }
        // The window's content: Home's page in the main pane, at the window's left edge while the window's sidebar is hidden.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = root
        split.frame = root.bounds
        root.addSubview(split)
        split.setWidth(320)
        TrafficLightsLine.apply(in: window)
        settle(home, split)
        let hidden = frames(window, home)
        try #require(hidden["lights over the list"] == CGRect(x: 1, y: 1, width: 1, height: 1), "SETUP: the lights lie over Home's list: \(hidden)")
        try #require(hidden["search"].map { !$0.isEmpty } == true, "SETUP: no search field: \(hidden)")

        // The window's sidebar shows: Home's page moves right by the sidebar's width, the lights stay in the window's corner.
        split.frame = NSRect(x: 300, y: 0, width: 900, height: 800)
        settle(home, split)
        let shown = frames(window, home)
        try #require(shown["lights over the list"] == .zero, "SETUP: the lights are clear of Home's list: \(shown)")

        var worst: CGFloat = 0
        for (name, rect) in hidden.sorted(by: { $0.key < $1.key }) where name != "lights over the list" {
            let after = try #require(shown[name], "\(name) went away when the sidebar showed")
            // Its height in the window: a toggle moves Home sideways, never up or down.
            let moved = max(abs(after.minY - rect.minY), abs(after.maxY - rect.maxY))
            worst = max(worst, moved)
            print("HOME_LIST_DRIFT|\(density.rawValue)|\(name)|\(moved)|hidden=\(rect)|shown=\(after)")
            #expect(moved <= 0.5, "\(density): Home's \(name) moved \(moved) pt up or down when the window's sidebar showed: \(rect) -> \(after)")
        }
        print("HOME_LIST_DRIFT|\(density.rawValue)|max|\(worst)")

        // And back: the sidebar hides, everything comes back to where it was.
        split.frame = root.bounds
        settle(home, split)
        let again = frames(window, home)
        for (name, rect) in hidden.sorted(by: { $0.key < $1.key }) {
            #expect(again[name] == rect, "\(density): Home's \(name) did not come back when the sidebar hid: \(rect) -> \(String(describing: again[name]))")
        }
    }

    private func settle(_ home: HomeSidebarView, _ split: NSView) {
        split.needsLayout = true
        split.layoutSubtreeIfNeeded()
        home.updateWindowControlsAvoidance()
        (split as? HomeSidebarSplitView)?.chatColumn.updateWindowControlsAvoidance()
        home.list.headerView.needsLayout = true
        home.list.headerView.layoutSubtreeIfNeeded()
    }

    /// Home's header in the window: the search field, the filter button, the list's top and the chat's compose button.
    private func frames(_ window: NSWindow, _ home: HomeSidebarView) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        // A marker, not a place: whether the lights lie over the list's header now.
        out["lights over the list"] = home.list.headerView.homeWindowControls(band: HomeSidebarHeaderLayout.band) == nil
            ? .zero : CGRect(x: 1, y: 1, width: 1, height: 1)
        let field = home.list.searchField
        out["search"] = field.convert(field.bounds, to: nil)
        out["filter"] = home.unreadToggle.convert(home.unreadToggle.bounds, to: nil)
        let list = home.list.scrollView
        out["list"] = list.convert(list.bounds, to: nil)
        if !home.chatCompose.isHidden { out["chat compose"] = home.chatCompose.convert(home.chatCompose.bounds, to: nil) }
        return out
    }
}
