import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextHome
import CmuxNextHomeEngine
import Foundation
import Testing

/// The Home header's top-right panel toggles (Leo 2026-10-20: "Use top-right toggle buttons (like
/// Claude desktop) to open the glossary/views, inspector, etc. Nothing opens by default"): each
/// button lights while its panel is open and runs its panel's toggle action; the Memory toggle
/// closes the Memory Inspector tab Home's right column shows, else opens one.
@MainActor @Suite(.serialized)
struct HomeHeaderPanelsTests {
    private struct Harness {
        let services: AppServices
        let controller: WindowController
        let defaults: UserDefaults
        let suite: String

        func context(isChief: Bool) -> HomeHeaderPanelContext {
            HomeHeaderPanelContext(services: services, window: controller, isChief: isChief, chief: nil, server: nil)
        }

        func close() {
            for controller in services.windows.controllers { controller.window?.close() }
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private static func harness() throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let suite = "cmux-home-header-panels-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        services.rightSidebarDefaults = defaults
        services.windows.ordersWindowsIn = false
        AppActions.bind(services)
        let controller = try #require(services.windows.openWindow(workspaces: ["hp-workspace"]))
        return Harness(services: services, controller: controller, defaults: defaults, suite: suite)
    }

    @Test func theToggleActionIsInThePaletteInEveryBuild() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let descriptor = try #require(services.registry.descriptor(for: ChiefInspectorHandlers.toggleActionID))
        #expect(!descriptor.isDebugOnly)
        #expect(descriptor.surfaces.contains(.palette))
        #expect(services.registry.unavailableReason(for: ChiefInspectorHandlers.toggleActionID) == nil)
    }

    @Test func withNoWindowTheToggleRefusesAndOpensNothing() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform(ChiefInspectorHandlers.toggleActionID, invocation: ActionInvocation(origin: .user))
        }
        #expect(refusal != nil)
        #expect(services.pages.keys(of: .chiefMemory).isEmpty)
    }

    /// Nothing is open by default: a fresh window's header shows every toggle off (a Chief's
    /// conversation), and only the sidebar toggle elsewhere. Share Screen with Chief shows even
    /// while the Debug toggle hides the rest: it is the sharing indicator too.
    @Test func aFreshWindowShowsEveryToggleOff() throws {
        let h = try Self.harness()
        defer { h.close() }
        let chief = HomeHeaderPanels.items(h.context(isChief: true), enabled: true)
        #expect(chief.map(\.id) == ["screenShare", "memory", "rightSidebar"])
        #expect(chief.allSatisfy { !$0.isOn }, "nothing opens on the right by default")
        #expect(!h.controller.rightSidebar.isVisible)
        let dm = HomeHeaderPanels.items(h.context(isChief: false), enabled: true)
        #expect(dm.map(\.id) == ["rightSidebar"], "a DM has no Chief memory")
        #expect(HomeHeaderPanels.items(h.context(isChief: true), enabled: false).map(\.id) == ["screenShare"],
                "the Debug toggle hides the cluster but the sharing toggle")
        #expect(HomeHeaderPanels.items(h.context(isChief: false), enabled: false).isEmpty)
    }

    /// The sidebar toggle follows the window's right sidebar, whichever entry point moved it, and a
    /// click on it toggles that sidebar.
    @Test func theSidebarToggleFollowsTheModelAndTogglesIt() throws {
        let h = try Self.harness()
        defer { h.close() }
        let isOn = { HomeHeaderPanels.items(h.context(isChief: false), enabled: true).first { $0.id == "rightSidebar" }?.isOn }
        #expect(isOn() == false)
        #expect(h.services.registry.perform("toggleRightSidebar"))
        #expect(isOn() == true, "the palette or ⌥⌘B opened it: the button lights")
        #expect(HomeHeaderPanels.toggle("rightSidebar", h.context(isChief: false)))
        #expect(!h.controller.rightSidebar.isVisible, "the button closed it")
        #expect(isOn() == false)
        #expect(HomeHeaderPanels.toggle("rightSidebar", h.context(isChief: false)))
        #expect(h.controller.rightSidebar.isVisible, "and opens it again")
        #expect(isOn() == true)
    }

    /// The tooltip carries the panel action's shortcut.
    @Test func theSidebarTooltipShowsItsShortcut() throws {
        let h = try Self.harness()
        defer { h.close() }
        let item = try #require(HomeHeaderPanels.items(h.context(isChief: false), enabled: true).first)
        #expect(item.shortcut == h.services.registry.shortcutDisplay(for: "toggleRightSidebar"))
        #expect(item.shortcut != nil)
    }

    /// Home as the daemon lists it: the pinned dock (Home's page) and, when given, a right column.
    private static func home(right: [TabSnapshot]?) -> DaemonStore {
        let store = DaemonStore()
        var page = TabSnapshot(surface: 1, kind: .conversation, title: "Home")
        page.conversation = ConversationTabRef(page: HomeDock.page)
        let dock = DockSnapshot(edge: .left, mode: .docked, role: .agentChat, isPinned: true)
        var columns = [ColumnSnapshot(id: 10, width: 0.5, layout: .leaf(1), dock: dock)]
        var panes = [PaneSnapshot(id: 1, tabs: [page])]
        if let right {
            columns.append(ColumnSnapshot(id: 11, width: 0.5, layout: .leaf(2)))
            panes.append(PaneSnapshot(id: 2, tabs: right))
        }
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), columns: columns, panes: panes)
        var workspace = WorkspaceSnapshot(id: 1, key: nil, name: "Home", screens: [screen])
        workspace.kind = "home"
        store.apply(snapshot: DaemonTree(workspaces: [workspace]))
        return store
    }

    /// The Memory toggle lights while Home's right column holds a Memory Inspector tab (the tree's
    /// page tab), and not for other page tabs or a terminal beside it.
    @Test func theMemoryToggleReadsTheMemoryTabBesideHome() throws {
        var memory = TabSnapshot(surface: 3, kind: .conversation, title: "Chief Memory")
        memory.conversation = ConversationTabRef(page: InternalPageID.chiefMemory.rawValue)
        var usage = TabSnapshot(surface: 4, kind: .conversation, title: "Chief Usage")
        usage.conversation = ConversationTabRef(page: "chief-usage")
        let shown = try #require(Self.home(right: [TabSnapshot(surface: 2, kind: .pty), memory]).workspaces.first)
        #expect(ChiefMemoryPageService.tabs(in: shown).map(\.surface) == [3])
        let others = try #require(Self.home(right: [TabSnapshot(surface: 2, kind: .pty), usage]).workspaces.first)
        #expect(ChiefMemoryPageService.tabs(in: others).isEmpty)
        let alone = try #require(Self.home(right: nil).workspaces.first)
        #expect(ChiefMemoryPageService.tabs(in: alone).isEmpty, "Home alone: nothing open on the right")
    }

    /// The bar draws the host's items and reports a click by id; the same ids keep their buttons.
    @Test func theBarDrawsItsItemsAndReportsClicks() throws {
        let bar = HomeHeaderPanelBar()
        var clicked: [String] = []
        bar.onToggle = { clicked.append($0) }
        bar.set([HomeHeaderPanelItem(id: "memory", symbol: "brain", label: "Memory Inspector", isOn: false),
                 HomeHeaderPanelItem(id: "rightSidebar", symbol: "sidebar.right", label: "Right Sidebar", shortcut: "⌥⌘B", isOn: true)])
        #expect(bar.buttons.count == 2)
        #expect(bar.intrinsicContentSize.width == 2 * HomeHeaderPanelBar.buttonSize + HomeHeaderPanelBar.spacing)
        #expect(bar.buttons.map(\.isOn) == [false, true])
        #expect(bar.buttons[1].themedToolTipShortcut == "⌥⌘B")
        #expect(bar.buttons[0].accessibilityLabel() == "Memory Inspector")
        let first = bar.buttons[0]
        bar.set([HomeHeaderPanelItem(id: "memory", symbol: "brain", label: "Memory Inspector", isOn: true),
                 HomeHeaderPanelItem(id: "rightSidebar", symbol: "sidebar.right", label: "Right Sidebar", isOn: false)])
        #expect(bar.buttons[0] === first, "a state change keeps the button")
        #expect(bar.buttons.map(\.isOn) == [true, false])
        bar.buttons[1].performClick(nil)
        #expect(clicked == ["rightSidebar"])
        // Only the buttons are hits: the gap drags the window with the header.
        bar.frame = NSRect(origin: .zero, size: bar.intrinsicContentSize)
        bar.layoutSubtreeIfNeeded()
        let superview = FlippedView(frame: bar.frame)
        superview.addSubview(bar)
        #expect(bar.hitTest(CGPoint(x: 14, y: 14)) === bar.buttons[0])
        #expect(bar.hitTest(CGPoint(x: HomeHeaderPanelBar.buttonSize + HomeHeaderPanelBar.spacing / 2, y: 14)) == nil)
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
