import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTabs
import Foundation
import Testing

/// cmux.json tab bar buttons -> registry actions -> strip buttons.
@MainActor
@Suite(.serialized) struct TabBarButtonsTests {
    typealias Coverage = ActionBindingCoverageTests

    @Test func defaultsResolveWithShortcutTooltips() {
        let registry = Coverage.boundServices().registry
        let resolved = TabBarButtonResolver.resolve(SurfaceTabBarConfig.builtInButtons, registry: registry)
        #expect(resolved.buttons.map(\.id) == ["cmux.newTerminal", "cmux.splitRight", "cmux.splitDown"])
        #expect(resolved.actions == ["cmux.newTerminal": "newSurface", "cmux.splitRight": "splitRight", "cmux.splitDown": "splitDown"])
        #expect(resolved.buttons.map(\.toolTip) == ["New Terminal Tab (⌃⇧⌘T)", "Split Right (⌘D)", "Split Down (⇧⌘D)"])
        #expect(resolved.buttons.map(\.accessibilityLabel) == ["New Terminal Tab", "Split Right", "Split Down"])
        #expect(resolved.buttons[1].icon == .symbol("square.split.2x1"))
    }

    @Test func rebindsShowInTooltipsAndUnknownActionsAreDropped() {
        let registry = Coverage.boundServices().registry
        registry.setShortcutOverride(nil, for: "splitRight")
        let specs = [
            TabBarButtonSpec(id: "cmux.splitRight", actionID: "splitRight"),
            TabBarButtonSpec(id: "sidebar", actionID: "toggleSidebar", tooltip: "Sidebar"),
            TabBarButtonSpec(id: "bogus", actionID: "no.such.action"),
        ]
        let resolved = TabBarButtonResolver.resolve(specs, registry: registry)
        #expect(resolved.buttons.map(\.id) == ["cmux.splitRight", "sidebar"])
        #expect(resolved.buttons[0].toolTip == "Split Right")
        // No icon in the spec: the catalog symbol.
        #expect(resolved.buttons[0].icon == .symbol(registry.descriptor(for: "splitRight")!.symbol))
        #expect(resolved.buttons[1].toolTip.hasPrefix("Sidebar"))
        #expect(resolved.unknown.map(\.id) == ["bogus"])
    }

    @Test func configCommandActionsAreRegisteredAndReplaced() throws {
        let services = Coverage.boundServices()
        let controller = services.tabBarButtons!
        let command = ConfigCommandAction(name: "start-claude", title: "Start Claude", command: "claude")
        controller.apply(TabBarButtonsController.Input(
            tabBar: SurfaceTabBarConfig(buttons: [
                TabBarButtonSpec(id: "start-claude", actionID: command.actionID, title: command.title),
                TabBarButtonSpec(id: "cmux.splitDown", actionID: "splitDown"),
            ], usesDefaults: false),
            commands: [command]
        ))
        #expect(services.registry.isBound("cmuxConfig.start-claude"))
        #expect(controller.buttons.map(\.id) == ["start-claude", "cmux.splitDown"])
        #expect(controller.actions["start-claude"] == "cmuxConfig.start-claude")
        // The button runs the registry action through the shared target
        // resolution: an unknown pane is refused, not sent to the focus.
        let outcome = Coverage.run(services, "cmuxConfig.start-claude", target: ActionTargetRef(kind: .pane, id: "p404"))
        guard case .refused = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }

        controller.apply(TabBarButtonsController.Input(tabBar: .defaults, commands: []))
        #expect(!services.registry.isBound("cmuxConfig.start-claude"))
        // No cmux.json list: no configured buttons, the default ones instead.
        #expect(controller.buttons.isEmpty)
        #expect(controller.buttons(for: .terminal).map(\.id) == ["cmux.splitRight", "cmux.splitDown"])
    }

    /// Without a cmux.json list, terminal and browser panes show Split Right
    /// and Split Down as two plain buttons; agent chat panes show none. A
    /// list replaces them everywhere.
    @Test func defaultButtonsFollowTheSelectedTabsKind() {
        let services = Coverage.boundServices()
        let controller = services.tabBarButtons!
        controller.apply(TabBarButtonsController.Input(tabBar: .defaults, commands: []))
        for kind in [PaneToolbar.Kind.terminal, .browser] {
            let buttons = controller.buttons(for: kind)
            #expect(buttons.map(\.id) == ["cmux.splitRight", "cmux.splitDown"])
            #expect(buttons.map(\.icon) == [.symbol("square.split.2x1"), .symbol("square.split.1x2")])
            #expect(buttons.map(\.toolTip) == ["Split Right (⌘D)", "Split Down (⇧⌘D)"])
            #expect(buttons.allSatisfy { !$0.opensMenu })
        }
        #expect(controller.buttons(for: .agent).isEmpty)
        #expect(controller.actions["cmux.splitRight"] == "splitRight")
        #expect(controller.actions["cmux.splitDown"] == "splitDown")

        controller.apply(TabBarButtonsController.Input(
            tabBar: SurfaceTabBarConfig(buttons: [TabBarButtonSpec(id: "cmux.splitDown", actionID: "splitDown")], usesDefaults: false),
            commands: []
        ))
        #expect(controller.buttons(for: .agent).map(\.id) == ["cmux.splitDown"])
        #expect(controller.buttons(for: .terminal).map(\.id) == ["cmux.splitDown"])
    }

    /// Up to four buttons all stay visible, as configured, with no "...".
    @Test func fourButtonsStayVisible() {
        let services = Coverage.boundServices()
        let controller = services.tabBarButtons!
        let specs = [
            TabBarButtonSpec(id: "cmux.newTerminal", actionID: "newSurface"),
            TabBarButtonSpec(id: "cmux.newBrowser", actionID: "openBrowser"),
            TabBarButtonSpec(id: "cmux.splitRight", actionID: "splitRight"),
            TabBarButtonSpec(id: "cmux.splitDown", actionID: "splitDown"),
        ]
        controller.apply(TabBarButtonsController.Input(tabBar: SurfaceTabBarConfig(buttons: specs, usesDefaults: false), commands: []))
        for kind in PaneToolbar.Kind.allCases {
            #expect(controller.buttons(for: kind).map(\.id) == specs.map(\.id))
            #expect(controller.overflowMenu(for: kind, paneKey: "p1").items.isEmpty)
        }
    }

    /// Past four buttons the strip keeps the first three and "..." lists the
    /// rest; each row runs its button's action on the pane, under the
    /// button's own label.
    @Test func moreThanFourButtonsEndInMore() throws {
        let services = Coverage.boundServices()
        let controller = services.tabBarButtons!
        let command = ConfigCommandAction(name: "start-claude", title: "Start Claude", command: "claude")
        let specs = [
            TabBarButtonSpec(id: "cmux.newTerminal", actionID: "newSurface"),
            TabBarButtonSpec(id: "cmux.newBrowser", actionID: "openBrowser"),
            TabBarButtonSpec(id: "cmux.splitRight", actionID: "splitRight"),
            TabBarButtonSpec(id: "cmux.splitDown", actionID: "splitDown"),
            TabBarButtonSpec(id: "start-claude", actionID: command.actionID, title: command.title),
        ]
        controller.apply(TabBarButtonsController.Input(tabBar: SurfaceTabBarConfig(buttons: specs, usesDefaults: false), commands: [command]))
        let visible = controller.buttons(for: .terminal)
        #expect(visible.count == PaneToolbar.maxVisibleButtons)
        #expect(visible.map(\.id) == ["cmux.newTerminal", "cmux.newBrowser", "cmux.splitRight", PaneToolbar.moreID])
        let more = try #require(visible.last)
        #expect(more.opensMenu)
        #expect(more.icon == .symbol("ellipsis"))

        let menu = controller.overflowMenu(for: .terminal, paneKey: "p1")
        #expect(menu.items.map(\.title) == ["Split Down", "Start Claude"])
        let runs = menu.items.compactMap(ActionRegistry.menuRun(of:))
        #expect(runs.map(\.id) == ["splitDown", "cmuxConfig.start-claude"])
        #expect(runs.allSatisfy { $0.target == ActionTargetRef(kind: .pane, id: "p1") })
        #expect(menu.items.first?.keyEquivalent.lowercased() == "d")
    }

    @Test func buttonsFollowCmuxJSONLive() async throws {
        let services = Coverage.boundServices()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-next-tabbar-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"ui": {"surfaceTabBar": {"buttons": ["cmux.splitRight", "cmux.splitDown"]}}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url)
        settings.start()
        defer { settings.stop() }
        let controller = services.tabBarButtons!
        controller.start(settings: settings)
        defer { controller.stop() }
        try await eventually(settings) { controller.buttons.map(\.id) == ["cmux.splitRight", "cmux.splitDown"] }

        try Data(#"{"actions": {"go": {"type": "command", "command": "ls"}}, "ui": {"surfaceTabBar": {"buttons": ["go", "cmux.newBrowser"]}}}"#.utf8)
            .write(to: url, options: .atomic)
        try await eventually(settings) { controller.buttons.map(\.id) == ["go", "cmux.newBrowser"] }
        #expect(controller.actions == ["go": "cmuxConfig.go", "cmux.newBrowser": "openBrowser"])

        // A shortcut rebind in the file updates the tooltip of a listed button.
        try Data(#"{"shortcuts": {"splitRight": "cmd+\\"}, "ui": {"surfaceTabBar": {"buttons": ["cmux.splitRight"]}}}"#.utf8)
            .write(to: url, options: .atomic)
        try await eventually(settings) { controller.buttons.first { $0.id == "cmux.splitRight" }?.toolTip == "Split Right (⌘\\)" }
        #expect(!services.registry.isBound("cmuxConfig.go"))
    }

    /// Waits (bounded) for settings loads and main-actor observation hops.
    private func eventually(_ settings: SettingsController, line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<40 where !condition() {
            let target = settings.loadCount + 1
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { await settings.waitForLoad(atLeast: target) }
                group.addTask { try await Task.sleep(for: .milliseconds(250)) }
                try await group.next()
                group.cancelAll()
            }
            await Task.yield()
        }
        #expect(condition(), "line \(line)")
    }
}
