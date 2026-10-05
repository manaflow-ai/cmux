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
        // No cmux.json list: no configured buttons, the default cluster instead.
        #expect(controller.buttons.isEmpty)
        #expect(controller.buttons(for: .terminal).map(\.id) == [PaneToolbar.splitID, PaneToolbar.moreID])
    }

    /// Without a cmux.json list each pane shows at most two buttons after
    /// its "+", by the selected tab's kind; a list replaces them everywhere.
    @Test func defaultClusterFollowsTheSelectedTabsKind() {
        let services = Coverage.boundServices()
        let controller = services.tabBarButtons!
        controller.apply(TabBarButtonsController.Input(tabBar: .defaults, commands: []))
        #expect(controller.buttons(for: .terminal).map(\.id) == ["cmux.split", "cmux.more"])
        #expect(controller.buttons(for: .browser).map(\.id) == ["cmux.split", "cmux.more"])
        #expect(controller.buttons(for: .agent).map(\.id) == ["cmux.more"])
        for kind in PaneToolbar.Kind.allCases { #expect(controller.buttons(for: kind).count <= 3) }
        let split = controller.buttons(for: .terminal)[0]
        #expect(split.toolTip == "Split Right (⌘D)")
        #expect(split.menu == .secondary)
        #expect(controller.buttons(for: .terminal)[1].menu == .primary)
        #expect(controller.actions["cmux.split"] == "splitRight")
        #expect(controller.alternates["cmux.split"] == "splitDown")

        controller.apply(TabBarButtonsController.Input(
            tabBar: SurfaceTabBarConfig(buttons: [TabBarButtonSpec(id: "cmux.splitDown", actionID: "splitDown")], usesDefaults: false),
            commands: []
        ))
        #expect(controller.buttons(for: .agent).map(\.id) == ["cmux.splitDown"])
        #expect(controller.alternates.isEmpty)
        #expect(controller.actions["cmux.split"] == nil)
    }

    /// Split's menu offers both directions; More holds files, folder,
    /// windows and the tab's duplicate and move, plus the splits when the
    /// strip shows no split button (agent chat). Each row keeps its shortcut.
    @Test func clusterMenusRunRegistryActions() throws {
        let registry = Coverage.boundServices().registry
        func ids(_ menu: NSMenu?) -> [String] {
            (menu?.items ?? []).map { ActionRegistry.menuRun(of: $0)?.id.rawValue ?? ($0.isSeparatorItem ? "|" : "?") }
        }
        let split = PaneToolbar.menu(for: PaneToolbar.splitID, kind: .terminal, pane: "p1", tab: "t1", registry: registry)
        #expect(ids(split) == ["splitRight", "splitDown"])
        let terminalMore = PaneToolbar.menu(for: PaneToolbar.moreID, kind: .terminal, pane: "p1", tab: "t1", registry: registry)
        #expect(ids(terminalMore) == ["toggleRightSidebar", "openFolder", "newWindow", "|", "duplicateTab", "tab.moveToNewWindow"])
        let agentMore = PaneToolbar.menu(for: PaneToolbar.moreID, kind: .agent, pane: "p1", tab: "t1", registry: registry)
        #expect(ids(agentMore).prefix(3) == ["splitRight", "splitDown", "|"])
        // Tab rows run on the selected tab, split rows on the pane.
        #expect(terminalMore.flatMap { ActionRegistry.menuRun(of: $0.items.last!)?.target } == ActionTargetRef(kind: .tab, id: "t1"))
        #expect(split.flatMap { ActionRegistry.menuRun(of: $0.items[0])?.target } == ActionTargetRef(kind: .pane, id: "p1"))
        let down = try #require(split?.items.last)
        #expect(down.keyEquivalent.lowercased() == "d")
        #expect(PaneToolbar.menu(for: "cmux.splitRight", kind: .terminal, pane: "p1", tab: nil, registry: registry) == nil)
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

        // A shortcut rebind in the file updates the tooltip. The default bar
        // has no buttons (R120), so the file lists the one it checks.
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
