import AppKit
@testable import CmuxNextApp
@testable import CmuxHomeCore
import CmuxNextSidebar
import CmuxNextDesign
@testable import CmuxNextOnboarding
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
import CmuxNextTestSupport
import Foundation
@testable import MessagesLabHome
@testable import MessagesLabSidebar
import Testing

/// Goal a11y-baseline (cmuxterm-hq goals/a11y-baseline.md): VoiceOver meets no control on Home that
/// it can only speak as its role. The probe's first whole read of a fresh Nightly (cmuxterm-hq
/// synthetic-probes run 42599053150, 2026-11-09) found unnamed buttons in the main window, four of
/// them after the Home list's Unread Messages filter. Leo, 2026-11-08: "Every conceivable possible
/// aspect of the app, and also in how we do the app, and just that, like how we work, how we look
/// like to other people, how we can introduce other people to our thing, that kind of thing."
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeAccessibilityNamesTests {
    /// The roles the probe counts as controls (a11y_walk_probe.py CONTROL_ROLES).
    static let controlRoles: Set<NSAccessibility.Role> = [
        .button, .popUpButton, .menuButton, .checkBox, .radioButton, .link, .textField, .textArea, .comboBox,
        .slider, .incrementor, .disclosureTriangle, .colorWell,
    ]

    /// One line per control under `root` with no label or title, naming its class and frame.
    static func unnamed(under root: Any) -> [String] {
        AccessibilityAudit().nodes(under: root).compactMap { node in
            guard controlRoles.contains(node.role), node.label.isEmpty else { return nil }
            let view = (node.element as? NSView) ?? (node.element as? NSCell)?.controlView
            let frame = view.map { $0.convert($0.bounds, to: nil) } ?? .zero
            let help = (node.element as? any NSAccessibilityProtocol)?.accessibilityHelp() ?? ""
            return "\(node.path) \(String(describing: type(of: node.element))) id=\(node.identifier) help=\(help) frame=\(frame)"
        }
    }

    /// Home as a fresh window shows it: the list beside the first-run chat with its composer.
    @Test func homeListAndChatNameEveryControl() throws {
        _ = NSApplication.shared
        let suite = "cmux.tests.homeAccessibilityNames.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        let chat = HomeNativeTranscriptView(store: store, conversation: ConversationID("conv_names"), me: ParticipantID("user_me"))
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 800))
        let split = HomeSidebarSplitView(sidebar: home, content: chat, widths: HomeSidebarWidth(defaults: defaults))
        split.windowKey = { "w" }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = split
        window.nameStandardWindowButtons() // as `install(kind:)` does for every cmux window
        split.layoutSubtreeIfNeeded()
        split.setWidth(320)
        split.layoutSubtreeIfNeeded()
        home.list.headerView.needsLayout = true
        home.list.headerView.layoutSubtreeIfNeeded()
        Self.dump("split", window)
        let unnamed = Self.unnamed(under: window)
        #expect(unnamed.isEmpty, "\(unnamed.count) unnamed controls on Home:\n\(unnamed.joined(separator: "\n"))")
    }

    /// Every control under `root`, named or not, for the run's log.
    static func dump(_ scene: String, _ root: Any) {
        let lines = AccessibilityAudit().nodes(under: root).filter { controlRoles.contains($0.role) || $0.role == .row }.map { node in
            let view = (node.element as? NSView) ?? (node.element as? NSCell)?.controlView
            let frame = view.map { $0.convert($0.bounds, to: nil) } ?? .zero
            return "  \(node.path) [\(node.label)] \(String(describing: type(of: node.element))) id=\(node.identifier) frame=\(frame)"
        }
        print("a11y-dump \(scene): \(lines.count) controls\n\(lines.joined(separator: "\n"))")
    }

    private static func wait(_ limit: Duration = .seconds(10), until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// The docked Home and a Home tab as the app builds them, with the app's services.
    @Test func homeContainersNameEveryControl() async throws {
        _ = NSApplication.shared
        let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer { for window in NSApp.windows where !windowsBefore.contains(ObjectIdentifier(window)) { window.close() } }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let conversation = ConversationID("conv_names_dock")
        let dock = HomeDockView(services: services, mode: .messages)
        dock.messages?.show(conversation)
        let tab = TopHomePageView(services: services, windowKey: { "a11y-names" })
        tab.show(conversation)
        for (scene, view) in [("dock", dock as NSView), ("homeTab", tab as NSView)] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            window.contentView = view
            window.nameStandardWindowButtons()
            window.orderFrontRegardless()
            view.layoutSubtreeIfNeeded()
            await Self.wait { (dock.messages?.host?.focusTarget is NSTextView) || scene == "homeTab" && tab.host?.focusTarget is NSTextView }
            view.layoutSubtreeIfNeeded()
            Self.dump(scene, window)
            let unnamed = Self.unnamed(under: window)
            #expect(unnamed.isEmpty, "\(scene): \(unnamed.count) unnamed controls:\n\(unnamed.joined(separator: "\n"))")
        }
    }

    /// The main window's root (titlebar band, workspace sidebar) as a new window shows it.
    @Test func windowRootNamesEveryControl() throws {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        window.nameStandardWindowButtons()
        defer { window.close() }
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        Self.dump("windowRoot", window)
        let unnamed = Self.unnamed(under: window)
        #expect(unnamed.isEmpty, "window root: \(unnamed.count) unnamed controls:\n\(unnamed.joined(separator: "\n"))")
    }

    /// The first-run Agents window (it covers Home on a fresh signed-out launch).
    @Test func agentsWindowNamesEveryControl() throws {
        let controller = OnboardingWindowController(model: OnboardingModel(services: MockOnboardingServices(), step: .agents), activeLook: nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        window.layoutIfNeeded()
        Self.dump("agents", window)
        let unnamed = Self.unnamed(under: window)
        #expect(unnamed.isEmpty, "Agents window: \(unnamed.count) unnamed controls:\n\(unnamed.joined(separator: "\n"))")
    }

    /// A scroller's arrow and page parts carry names: a stock one through `SystemScrollers.follow`
    /// (the Home list's, four unnamed buttons in the probe's read) and the thin one of its own.
    @Test(arguments: [false, true])
    func scrollerPartsAreNamed(_ thin: Bool) throws {
        _ = NSApplication.shared
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 2000))
        if thin { SystemScrollers.followThin(scrollView) } else { SystemScrollers.follow(scrollView) }
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = scrollView
        scrollView.layoutSubtreeIfNeeded()
        let scroller = try #require(scrollView.verticalScroller)
        let parts = (scroller.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
            .filter { $0.accessibilityRole() == .button }
        #expect(!parts.isEmpty || thin, "a stock scroller has its arrow and page parts")
        for part in parts {
            #expect(!(part.accessibilityLabel() ?? "").isEmpty, "\(String(describing: part.accessibilitySubrole())) has no name")
        }
    }
}
