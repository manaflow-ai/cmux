import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-21: the sidebar's workspace hover card "needs ... a way to toggle it off".
/// `sidebar.hoverCards.enabled` (Settings > Appearance > Sidebar > Show Hover Cards, on by
/// default) is also a checked row, Show Hover Cards, in the sidebar's menu and a workspace row's
/// menu (`sidebar.hoverCards.toggle`). Turning it off takes effect at once: no card opens on
/// hover, and a card that is open closes.
@MainActor @Suite(.serialized) struct SidebarHoverCardsToggleTests {
    // MARK: The setting

    @Test func hoverCardsAreOnByDefault() {
        #expect(HoverCardSettings.enabledDefault)
        #expect(HoverCardSettings().enabled)
        #expect(DesignSettings().hoverCardsEnabled)
        var diagnostics: [SettingsDiagnostic] = []
        #expect(HoverCardSettings.parse(.object([:]), diagnostics: &diagnostics).enabled)
        let off = JSONValue.object(["sidebar": .object(["hoverCards": .object(["enabled": .bool(false)])])])
        #expect(!HoverCardSettings.parse(off, diagnostics: &diagnostics).enabled)
        #expect(diagnostics.isEmpty, "\(diagnostics)")
    }

    // MARK: The menu row

    /// Every action a menu runs, with its row, submenus included.
    private static func rows(_ menu: NSMenu) -> [(ActionID, NSMenuItem)] {
        menu.items.flatMap { item in
            (ActionRegistry.menuRun(of: item).map { [($0.id, item)] } ?? []) + (item.submenu.map(rows) ?? [])
        }
    }

    private static func row(_ menu: NSMenu) -> NSMenuItem? {
        rows(menu).first { $0.0 == SidebarHoverCardsToggle.id }?.1
    }

    @Test func theSidebarAndWorkspaceMenusOfferShowHoverCards() {
        let registry = ActionRegistry.standard()
        registry.bind(SidebarHoverCardsToggle.id, invoke: { _ in })
        let background = Self.row(registry.makeContextMenu(for: .sidebarBackground))
        #expect(background?.title == "Show Hover Cards")
        let workspace = Self.row(registry.makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: "ws")))
        #expect(workspace?.title == "Show Hover Cards")
    }

    /// The row flips `sidebar.hoverCards.enabled` in cmux.json, checked while cards are on, and
    /// the live design value follows (no relaunch).
    @Test func theRowFlipsTheSettingAndTheLiveValue() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-hover-cards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let design = DesignSettings()
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: design, fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()

        func saved() -> Bool? {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return ((root["sidebar"] as? [String: Any])?["hoverCards"] as? [String: Any])?["enabled"] as? Bool
        }
        func until(_ condition: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        }
        func checked() -> Bool? { Self.row(services.registry.makeContextMenu(for: .sidebarBackground)).map { $0.state == .on } }

        #expect(design.hoverCardsEnabled)
        #expect(checked() == true, "Show Hover Cards is not checked while cards are on")
        #expect(services.registry.perform(SidebarHoverCardsToggle.id, invocation: ActionInvocation()))
        await until { saved() == false && !design.hoverCardsEnabled }
        #expect(saved() == false)
        #expect(!design.hoverCardsEnabled, "turning hover cards off did not reach the live value")
        #expect(checked() == false, "Show Hover Cards is still checked with cards off")
        #expect(services.registry.perform(SidebarHoverCardsToggle.id, invocation: ActionInvocation()))
        await until { saved() == true && design.hoverCardsEnabled }
        #expect(saved() == true)
        #expect(design.hoverCardsEnabled)
    }

    // MARK: The card

    /// Three workspace rows in an ordered-front window, on a coordinator that hit-tests that
    /// window and reads whether cards are on from `design`.
    private static func sidebar(clock: ManualClock, design: DesignSettings) -> (SidebarListView, NSWindow, HoverCardCoordinator, [SidebarRow]) {
        _ = NSApplication.shared
        let workspaces = (1...3).map {
            SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "workspace-\($0)", directory: "~/Projects/site-\($0)", branch: "main")
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })],
                                 activeWorkspaceID: nil)
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let coordinator = HoverCardCoordinator(clock: clock)
        coordinator.appIsActive = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.hoverCardsEnabled = { [weak design] in design?.showsHoverCards ?? true }
        coordinator.windowNumberAt = { [weak window] _ in window?.windowNumber }
        coordinator.pointerLocation = { .zero }
        list.hoverCards = coordinator
        window.contentView = list
        list.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        window.orderFrontRegardless()
        list.reload(animated: false)
        let rows = list.displayed.rows.filter { if case .workspace = $0.key { true } else { false } }
        return (list, window, coordinator, rows)
    }

    private static func settle(until done: (() -> Bool)? = nil) async throws {
        for _ in 0..<20 { await Task.yield() }
        for _ in 0..<(done == nil ? 3 : 500) where done?() != true { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Rests the pointer on `row` past the hover card delay.
    private static func rest(_ list: SidebarListView, _ coordinator: HoverCardCoordinator, on row: SidebarRow, clock: ManualClock) async throws {
        list.updateHover(list.convert(NSPoint(x: list.bounds.midX, y: (row.y + row.maxY) / 2), to: nil))
        if case .pending = coordinator.machine.phase { try await clock.waitForSleeper() }
        clock.advance(by: DesignSettings.shared.hoverCardDelay + .milliseconds(100))
    }

    @Test func offShowsNoCardAndTurningOffClosesTheOpenOne() async throws {
        let clock = ManualClock()
        let design = DesignSettings()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock, design: design)
        defer {
            coordinator.dismiss(.action)
            window.contentView = nil
            window.close()
        }
        try #require(rows.count == 3)

        // Off: resting on a row opens no card.
        design.hoverCardsEnabled = false
        try await Self.rest(list, coordinator, on: rows[0], clock: clock)
        try await Self.settle()
        #expect(coordinator.machine.shownTarget == nil, "a card opened with hover cards off")

        // On again: the next rest opens the row's card, with no relaunch.
        design.hoverCardsEnabled = true
        try await Self.rest(list, coordinator, on: rows[1], clock: clock)
        try await Self.settle(until: { coordinator.machine.shownTarget != nil })
        try #require(coordinator.machine.shownTarget != nil, "turning hover cards back on did not bring the card back")

        // Off while the card is open: it closes at once.
        design.hoverCardsEnabled = false
        try await Self.settle()
        #expect(coordinator.machine.shownTarget == nil, "the open card stayed after hover cards were turned off")
    }
}
