import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// The sidebar's bottom band hides the macOS way (Leo, cx-wab7m): right-click a piece for
/// "Hide <piece>", right-click the band where it was for "Show <piece>". No trip to Settings.
/// Each piece is a cmux.json setting (`sidebar.showSpaces`, `sidebar.showProfileControl`), so a
/// hidden piece stays hidden after a relaunch, and Settings shows the same switch.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarBandHideTests {
    struct Harness {
        let services: AppServices
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        let url: URL

        /// `sidebar.<key>` as cmux.json holds it now.
        func saved(_ key: String) -> Bool? {
            guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (root["sidebar"] as? [String: Any])?[key] as? Bool
        }
        var account: LayoutItemID { LayoutItemID("itm_account") }
        var showsProfileControl: Bool { sidebar.footerRegion.itemView(account) != nil }

        func tearDown() {
            window.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        /// The menu a right-click at `point` (the sidebar's coordinates) opens: the hit view's,
        /// else its superviews' in turn, as AppKit passes an unhandled right-click up.
        func rightClick(at point: NSPoint) -> NSMenu? {
            sidebar.layoutSubtreeIfNeeded()
            let location = sidebar.convert(point, to: nil)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let superview = sidebar.superview else { return nil }
            var view = sidebar.hitTest(superview.convert(point, from: sidebar))
            while let current = view {
                if let menu = current.menu(for: event) { return menu }
                view = current === sidebar ? nil : current.superview
            }
            return nil
        }

        /// A right-click in the band's empty space, at the sidebar's bottom-right.
        func rightClickBand() -> [String] {
            titles(rightClick(at: NSPoint(x: sidebar.bounds.maxX - 8, y: sidebar.bounds.maxY - 6)))
        }

        /// Waits for `condition` up to a deadline: the settings write and reload run on other
        /// tasks, which a fixed count of yields outran on a busy runner.
        func until(_ condition: () -> Bool, within timeout: Duration = .seconds(10)) async {
            let deadline = ContinuousClock.now + timeout
            while !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
                sidebar.needsLayout = true
                sidebar.layoutSubtreeIfNeeded()
            }
        }
    }

    func make(_ json: String = "{}") async throws -> Harness {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-band-hide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(json.utf8).write(to: url)
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        // The sidebar draws from the settings controller's design settings, as in the app (its own
        // instance here: suites run in parallel, and another sidebar reads the shared one).
        let design = DesignSettings()
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: design, fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()

        let model = SidebarModel()
        model.profiles = (0..<2).map { SidebarProfile(id: ProfileKey("space\($0)"), name: "Space \($0)") }
        let sidebar = SidebarView(model: model, design: design)
        sidebar.contextMenuProvider = { target in
            SidebarContextMenus.menu(for: target, model: model, services: services, scope: ThemeScope(level: .room))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false // ARC owns it; close() would release it once more
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        let harness = Harness(services: services, model: model, sidebar: sidebar, window: window, url: url)
        // Let the first layout and the settings load settle.
        await harness.until({ false }, within: .milliseconds(200))
        return harness
    }

    /// Every row title in `menu`, its submenus' too.
    static func titles(_ menu: NSMenu?) -> [String] {
        (menu?.items ?? []).flatMap { [$0.title] + titles($0.submenu) }.filter { !$0.isEmpty }
    }

    @Test func aSpaceDotHidesTheSpacesAndTheBandShowsThemAgain() async throws {
        let h = try await make()
        defer { h.tearDown() }
        #expect(!h.sidebar.profileBar.isHidden)
        #expect(!h.rightClickBand().contains("Show Spaces"))

        // Right-click a dot: its menu offers Hide Spaces.
        let dotMenu = SidebarContextMenus.menu(for: .profile(ProfileKey("space0")), model: h.model, services: h.services,
                                               scope: ThemeScope(level: .room))
        #expect(Self.titles(dotMenu).contains("Hide Spaces"))
        _ = h.services.registry.perform("sidebar.spaces.hide", invocation: ActionInvocation(target: ActionTargetRef(kind: .profile, id: "space0")))
        await h.until { h.sidebar.profileBar.isHidden && h.saved("showSpaces") == false }
        #expect(h.sidebar.profileBar.isHidden)
        #expect(h.saved("showSpaces") == false)

        // Right-click the band where they were: Show Spaces, and only for what is hidden.
        let band = h.rightClickBand()
        #expect(band.contains("Show Spaces"))
        #expect(!band.contains("Show Profile Button"))
        _ = h.services.registry.perform("sidebar.spaces.show")
        await h.until { !h.sidebar.profileBar.isHidden && h.saved("showSpaces") == true }
        #expect(!h.sidebar.profileBar.isHidden)
        #expect(h.saved("showSpaces") == true)
    }

    @Test func theProfileButtonHidesFromItsMenuAndTheBandShowsItAgain() async throws {
        let h = try await make()
        defer { h.tearDown() }
        #expect(h.showsProfileControl)
        let itemMenu = h.services.registry.makeContextMenu(for: .sidebarItem, target: ActionTargetRef(kind: .sidebarItem, id: h.account.rawValue))
        #expect(Self.titles(itemMenu).contains("Hide Profile Button"))
        // Another item's menu has no Hide Profile Button.
        let other = h.services.registry.makeContextMenu(for: .sidebarItem, target: ActionTargetRef(kind: .sidebarItem, id: "itm_settings"))
        #expect(!Self.titles(other).contains("Hide Profile Button"))

        _ = h.services.registry.perform("sidebar.profileControl.hide",
                                        invocation: ActionInvocation(target: ActionTargetRef(kind: .sidebarItem, id: h.account.rawValue)))
        await h.until { !h.showsProfileControl && h.saved("showProfileControl") == false }
        #expect(!h.showsProfileControl)

        let band = h.rightClickBand()
        #expect(band.contains("Show Profile Button"))
        #expect(!band.contains("Show Spaces"))
        _ = h.services.registry.perform("sidebar.profileControl.show")
        await h.until { h.showsProfileControl && h.saved("showProfileControl") == true }
        #expect(h.showsProfileControl)
    }

    /// Relaunch: cmux.json still says hidden, so the band draws neither piece, and its empty
    /// space still offers both Show rows.
    @Test func hiddenPiecesStayHiddenAfterARelaunch() async throws {
        let h = try await make(#"{"sidebar":{"showSpaces":false,"showProfileControl":false}}"#)
        defer { h.tearDown() }
        #expect(h.sidebar.profileBar.isHidden)
        #expect(!h.showsProfileControl)
        let band = h.rightClickBand()
        #expect(band.contains("Show Spaces"))
        #expect(band.contains("Show Profile Button"))
    }
}
