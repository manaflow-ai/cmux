import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Agent interop: a computer-use agent (OpenAI computer use, cmux-cua, any AXUIElement client)
/// finds and presses every control of the window chrome through the accessibility tree. Each scene
/// hosts the real views in a window and walks the tree the way a client does; every pressable
/// element (button, menu button, tab, disclosure, splitter) has a label and a stable
/// `cmux.<area>.<control>` identifier, and no image is exposed without a description.
@MainActor @Suite(.serialized, .closesItsWindows) struct AgentInteropAccessibilityTests {
    private let audit = AccessibilityAudit()

    private func window(_ view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func expectClean(_ root: NSView, _ scene: String) {
        let violations = audit.violations(under: root)
        #expect(violations.isEmpty, "\(scene): \(violations.count) controls an agent cannot use:\n\(violations.joined(separator: "\n"))")
    }

    // MARK: Tab strip and pane controls

    @Test func tabStripTabsNewTabAndCloseAreNamedAndIdentified() throws {
        let tabs = (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }
        let strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: TabID("tab1")))
        strip.dragsWindowFromEmptySpace = false
        let host = window(strip, size: NSSize(width: 900, height: TabStripView.preferredHeight))
        defer { host.close() }

        // The walk reaches the strip's elements at all (a broken walk would pass vacuously).
        let labels = audit.nodes(under: strip).map(\.label)
        #expect(labels.contains(CmuxNextTabs.Strings.axNewTab), "the walk found \(labels)")

        expectClean(strip, "tab strip")
        let ids = audit.identifiers(under: strip)
        for expected in ["cmux.tabs.strip", "cmux.tabs.newTab", "cmux.tabs.tab.tab0", "cmux.tabs.tab.tab1", "cmux.tabs.tab.tab2"] {
            #expect(ids.contains(expected), "missing \(expected) in \(ids.sorted())")
        }
        // Each closable tab's x is a button an agent presses, not only a custom action. It draws on
        // hover only, so it is exposed where hovering shows it.
        for tab in ["tab0", "tab1", "tab2"] {
            let close = try #require(audit.nodes(under: strip).first { $0.identifier == "cmux.tabs.tab.\(tab).close" },
                                     "\(tab)'s x is not in \(ids.sorted())")
            #expect(close.role == .button && close.label == CmuxNextTabs.Strings.axClose)
        }
    }

    @Test func paneToolbarButtonsAreNamedAndIdentified() {
        let toolbar = PaneToolbarView(frame: .zero)
        toolbar.show([PaneToolbarItem(id: "pane.splitRight", title: "Split Right", symbol: "rectangle.split.2x1", shortcut: nil)],
                     more: true, lit: false)
        let host = window(toolbar, size: NSSize(width: 120, height: 32))
        defer { host.close() }
        expectClean(toolbar, "pane toolbar")
        let ids = audit.identifiers(under: toolbar)
        #expect(ids.contains("cmux.pane.more"), "\(ids.sorted())")
        #expect(ids.contains("cmux.pane.toolbar.pane.splitRight"), "\(ids.sorted())")
    }

    // MARK: Window toolbar band

    @Test func titlebarBandButtonsAreNamedAndIdentified() {
        let band = TitlebarToolbarBand(frame: .zero)
        band.describeToggle(title: "Toggle Left Sidebar", shortcut: nil)
        band.describeHistory(back: "Go Back", forward: "Go Forward")
        let host = window(band, size: NSSize(width: TitlebarToolbarBand.width, height: 32))
        defer { host.close() }
        expectClean(band, "titlebar band")
        let ids = audit.identifiers(under: band)
        for expected in ["cmux.titlebar.toggleSidebar", "cmux.titlebar.back", "cmux.titlebar.forward"] {
            #expect(ids.contains(expected), "missing \(expected) in \(ids.sorted())")
        }
    }

    // MARK: Sidebar

    @Test func sidebarRowsGroupsAndButtonsAreNamedAndIdentified() throws {
        let (sidebar, first) = try SidebarGroupChromeLookTests.sidebar()
        let host = window(sidebar, size: NSSize(width: 240, height: 600))
        defer { host.close() }
        expectClean(sidebar, "sidebar")
        let ids = audit.identifiers(under: sidebar)
        for expected in ["cmux.sidebar.newWorkspace", "cmux.sidebar.workspace.\(first.rawValue)",
                         "cmux.sidebar.group.\(SidebarGroupChromeLookTests.open.rawValue)",
                         "cmux.sidebar.group.\(SidebarGroupChromeLookTests.closed.rawValue)"] {
            #expect(ids.contains(expected), "missing \(expected) in \(ids.sorted())")
        }
    }

    @Test func spacesStripDotsAreNamedAndIdentified() {
        let model = SidebarModel()
        model.profiles = [SidebarProfile(id: ProfileKey("default"), name: "Default"), SidebarProfile(id: ProfileKey("work"), name: "Work")]
        model.activeProfileID = ProfileKey("default")
        let bar = ProfileBarView(model: model)
        let host = window(bar, size: NSSize(width: 240, height: 28))
        defer { host.close() }
        bar.refresh() // the sidebar refreshes the bar when its model changes
        expectClean(bar, "spaces strip")
        let ids = audit.identifiers(under: bar)
        for expected in ["cmux.sidebar.space.default", "cmux.sidebar.space.work", "cmux.sidebar.space.new"] {
            #expect(ids.contains(expected), "missing \(expected) in \(ids.sorted())")
        }
    }

    /// The group header's + and more show on hover; an agent that hovers the header finds both by id.
    @Test func groupHeaderActionsAreNamedAndIdentifiedWhenShown() throws {
        let (sidebar, _) = try SidebarGroupChromeLookTests.sidebar()
        let host = window(sidebar, size: NSSize(width: 240, height: 600))
        defer { host.close() }
        let header = try #require(sidebar.list.rowViews[.group(SidebarGroupChromeLookTests.open)] as? GroupHeaderRowView)
        header.isKeyboardFocused = true
        header.layoutSubtreeIfNeeded()
        expectClean(header, "group header with its actions shown")
        let group = SidebarGroupChromeLookTests.open.rawValue
        let ids = audit.identifiers(under: sidebar)
        #expect(ids.contains("cmux.sidebar.group.\(group).more"), "\(ids.sorted())")
        if header.onAdd != nil { #expect(ids.contains("cmux.sidebar.group.\(group).add"), "\(ids.sorted())") }
    }

    // MARK: Dividers

    @Test func paneDividersAndTheSidebarHandleAreIdentified() {
        let split = DividerHandleView(kind: .split(CmuxNextLayout.SplitID("split-a")), axis: .horizontal)
        let handle = SidebarResizeHandle(frame: .zero)
        let container = NSView()
        container.addSubview(split)
        container.addSubview(handle)
        let host = window(container, size: NSSize(width: 200, height: 200))
        defer { host.close() }
        split.frame = NSRect(x: 100, y: 0, width: 6, height: 200)
        handle.frame = NSRect(x: 0, y: 0, width: 6, height: 200)
        expectClean(container, "dividers")
        let ids = audit.identifiers(under: container)
        #expect(ids.contains("cmux.pane.divider.split-a"), "\(ids.sorted())")
        #expect(ids.contains("cmux.sidebar.resize"), "\(ids.sorted())")
    }
}
