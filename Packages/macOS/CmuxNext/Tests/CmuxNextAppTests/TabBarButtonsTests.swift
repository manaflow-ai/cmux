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
        let resolved = TabBarButtonResolver.resolve(SurfaceTabBarConfig.defaultButtons, registry: registry)
        #expect(resolved.buttons.map(\.id) == ["cmux.newTerminal", "cmux.splitRight", "cmux.splitDown"])
        #expect(resolved.actions == ["cmux.newTerminal": "newSurface", "cmux.splitRight": "splitRight", "cmux.splitDown": "splitDown"])
        #expect(resolved.buttons.map(\.toolTip) == ["New Terminal Tab (⌘T)", "Split Right (⌘D)", "Split Down (⇧⌘D)"])
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
        #expect(controller.buttons.map(\.id) == ["cmux.newTerminal", "cmux.splitRight", "cmux.splitDown"])
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

        // A shortcut rebind in the file updates the tooltip.
        try Data(#"{"shortcuts": {"splitRight": "cmd+\\"}}"#.utf8).write(to: url, options: .atomic)
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
