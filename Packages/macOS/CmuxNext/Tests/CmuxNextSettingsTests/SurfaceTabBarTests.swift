import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

@MainActor
@Suite struct SurfaceTabBarParsingTests {
    let directory = URL(filePath: "/tmp/cmux-config-test")

    func parse(_ text: String) throws -> SurfaceTabBarParser.Result {
        SurfaceTabBarParser.parse(try JSONC.parse(text), configDirectory: directory)
    }

    @Test func unsetUsesTheDefaults() throws {
        let result = try parse("{}")
        #expect(result.tabBar.usesDefaults)
        // R120: no trailing buttons by default; users add them back.
        #expect(result.tabBar.buttons.isEmpty)
        #expect(result.diagnostics.isEmpty)
    }

    @Test func parsesTheUsersConfig() throws {
        let result = try parse("""
        {
          "actions": {
            "start-claude": { "type": "agent", "agent": "claude", "args": "--dangerously-skip-permissions",
                              "icon": { "type": "image", "path": "icons/claude.svg" }, "tooltip": "Start Claude Code YOLO" },
            "start-opencode": { "type": "command", "command": "opencode", "tooltip": "Start opencode" }
          },
          "ui": { "surfaceTabBar": { "buttons": ["cmux.newTerminal", "cmux.newBrowser", "cmux.splitRight", "cmux.splitDown"] } }
        }
        """)
        #expect(!result.tabBar.usesDefaults)
        #expect(result.tabBar.buttons.map(\.id) == ["cmux.newTerminal", "cmux.newBrowser", "cmux.splitRight", "cmux.splitDown"])
        #expect(result.tabBar.buttons.map(\.actionID) == ["newSurface", "openBrowser", "splitRight", "splitDown"])
        #expect(result.tabBar.buttons.map(\.icon) == [.symbol("terminal"), .symbol("globe"), .symbol("square.split.2x1"), .symbol("square.split.1x2")])
        let claude = try #require(result.actions.first { $0.name == "start-claude" })
        #expect(claude.actionID == "cmuxConfig.start-claude")
        #expect(claude.command == "claude --dangerously-skip-permissions")
        #expect(claude.title == "Start Claude Code YOLO")
        #expect(claude.icon == .image(URL(filePath: "/tmp/cmux-config-test/icons/claude.svg")))
        #expect(claude.target == .newTabInCurrentPane)
        #expect(result.diagnostics.isEmpty)
    }

    @Test func emptyListHidesEveryButton() throws {
        let result = try parse(#"{"ui": {"surfaceTabBar": {"buttons": []}}}"#)
        #expect(!result.tabBar.usesDefaults)
        #expect(result.tabBar.buttons.isEmpty)
    }

    @Test func legacyRootKeyAndUIKeyPrecedence() throws {
        #expect(try parse(#"{"surfaceTabBarButtons": ["splitDown"]}"#).tabBar.buttons.map(\.actionID) == ["splitDown"])
        let both = try parse(#"{"surfaceTabBarButtons": ["splitDown"], "ui": {"surfaceTabBar": {"buttons": ["newBrowser"]}}}"#)
        #expect(both.tabBar.buttons.map(\.actionID) == ["openBrowser"])
    }

    @Test func objectEntriesReferenceActionsBuiltinsAndCommands() throws {
        let result = try parse("""
        {
          "actions": { "codex-new-tab": { "type": "agent", "agent": "codex", "title": "Codex", "target": "currentTerminal" } },
          "ui": { "surfaceTabBar": { "buttons": [
            { "action": "codex-new-tab", "title": "Codex!" },
            { "builtin": "splitRight", "icon": "arrow.right.square", "tooltip": "Right" },
            { "id": "cmux.splitDown" },
            { "command": "npm test", "title": "Test" },
            { "id": "ship", "agent": "claude-code", "args": "-p ship" },
            "toggleSidebar"
          ] } }
        }
        """)
        let buttons = result.tabBar.buttons
        #expect(buttons.map(\.id) == ["codex-new-tab", "cmux.splitRight", "cmux.splitDown", "command.npm test", "ship", "toggleSidebar"])
        #expect(buttons.map(\.actionID) == ["cmuxConfig.codex-new-tab", "splitRight", "splitDown", "cmuxConfig.command.npm test",
                                            "cmuxConfig.ship", "toggleSidebar"])
        #expect(buttons[0].title == "Codex!")
        #expect(buttons[1].icon == .symbol("arrow.right.square"))
        #expect(buttons[1].tooltip == "Right")
        #expect(buttons[3].icon == .symbol("terminal"))
        let byName = Dictionary(uniqueKeysWithValues: result.actions.map { ($0.name, $0) })
        #expect(byName["codex-new-tab"]?.target == .currentTerminal)
        #expect(byName["command.npm test"]?.command == "npm test")
        #expect(byName["ship"]?.command == "claude -p ship")
        #expect(result.diagnostics.isEmpty)
    }

    @Test func badEntriesAreReportedAndSkipped() throws {
        let result = try parse("""
        {
          "actions": { "ws": { "type": "workspaceCommand", "commandName": "dev" } },
          "ui": { "surfaceTabBar": { "buttons": [
            "cmux.splitRight", "splitRight", "", 42, "cmux.newSimulator", "ws",
            { "builtin": "nope" }, { "action": "a", "command": "b" }, { "type": "workspace" }, { "title": "orphan" }
          ] } }
        }
        """)
        #expect(result.tabBar.buttons.map(\.id) == ["cmux.splitRight", "ws"])
        // "ws" is not a runnable action, so it stays a raw registry reference
        // the App drops; the unsupported action type itself is reported.
        #expect(result.tabBar.buttons[1].actionID == "ws")
        let paths = result.diagnostics.map(\.path)
        #expect(paths.contains("actions.ws.type"))
        for index in [1, 2, 3, 4, 6, 7, 8, 9] {
            #expect(paths.contains { $0.hasPrefix("ui.surfaceTabBar.buttons.\(index)") }, "entry \(index)")
        }
    }

    @Test func nonArrayFallsBackToDefaults() throws {
        let result = try parse(#"{"ui": {"surfaceTabBar": {"buttons": "splitRight"}}}"#)
        #expect(result.tabBar.usesDefaults)
        #expect(result.diagnostics.map(\.path) == ["ui.surfaceTabBar.buttons"])
    }

    @Test func snapshotCarriesTheTabBar() throws {
        let root = try JSONC.parse(#"{"ui": {"surfaceTabBar": {"buttons": ["cmux.splitDown"]}}}"#)
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [], configDirectory: directory)
        #expect(snapshot.tabBar.buttons.map(\.actionID) == ["splitDown"])
        #expect(CmuxConfigSnapshot.empty.tabBar == .defaults)
    }
}

@MainActor
@Suite struct BuiltInButtonMappingTests {
    @Test func everyBuiltInMapsToACatalogAction() {
        let registry = ActionRegistry.standard()
        let ids = ["cmux.newTerminal", "cmux.newBrowser", "cmux.splitRight", "cmux.splitDown", "cmux.newWorkspace",
                   "cmux.newAgentChat", "cmux.newCloudWorkspace", "cmux.newCloudMachine", "cmux.mobileconnect"]
        for id in ids {
            let entry = BuiltInButtonActions.entry(for: id)
            #expect(entry?.configID == id)
            #expect(entry.flatMap { registry.descriptor(for: ActionID(rawValue: $0.actionID)) } != nil, "\(id)")
        }
        #expect(SurfaceTabBarConfig.defaultButtons.isEmpty)
    }

    @Test func aliasesResolveToTheCanonicalEntry() {
        #expect(BuiltInButtonActions.entry(for: "splitRight")?.actionID == "splitRight")
        #expect(BuiltInButtonActions.entry(for: "newTerminal")?.actionID == "newSurface")
        #expect(BuiltInButtonActions.entry(for: "cmux.mobileConnect")?.configID == "cmux.mobileconnect")
        #expect(BuiltInButtonActions.entry(for: "agentChat")?.actionID == "palette.newAgentChat")
        #expect(BuiltInButtonActions.entry(for: "splitLeft") == nil)
    }

    /// TAB-STRIP-TRAILING-BUTTONS-REMOVED: the strip draws no buttons, so
    /// their action names are not checked; the key itself is reported as
    /// ignored (by the file parse, ``SurfaceTabBarRemovedTests``).
    @Test func buttonActionNamesAreNotReported() throws {
        let registry = ActionRegistry.standard()
        let applier = SettingsApplier(design: DesignSettings(), registry: registry)
        let root = try JSONC.parse(#"{"ui": {"surfaceTabBar": {"buttons": ["splitRight", "does.not.exist"]}}}"#)
        let diagnostics = applier.apply(CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities,
                                                                validMetrics: SettingsApplier.validMetrics))
        #expect(diagnostics.filter { $0.path == "ui.surfaceTabBar.buttons" && $0.kind == .unknownAction }.isEmpty)
    }
}

/// TAB-STRIP-TRAILING-BUTTONS-REMOVED: a cmux.json that still sets the tab
/// bar buttons gets one diagnostic saying the key is ignored, instead of
/// silence (or a report of action names nothing runs).
@MainActor
@Suite struct SurfaceTabBarRemovedTests {
    static let message = "ignored: the tab bar buttons were removed"

    func diagnostics(_ text: String) throws -> [SettingsDiagnostic] {
        let root = try JSONC.parse(text)
        return CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities,
                                        validMetrics: SettingsApplier.validMetrics).diagnostics
    }

    @Test func aSetButtonListIsReportedAsIgnored() throws {
        let set = try diagnostics(#"{"ui": {"surfaceTabBar": {"buttons": ["splitRight", "does.not.exist"]}}}"#)
        #expect(set.filter { $0.message == Self.message }.map(\.path) == ["ui.surfaceTabBar.buttons"])
        let empty = try diagnostics(#"{"ui": {"surfaceTabBar": {"buttons": []}}}"#)
        #expect(empty.filter { $0.message == Self.message }.map(\.path) == ["ui.surfaceTabBar.buttons"])
        let wrongType = try diagnostics(#"{"ui": {"surfaceTabBar": {"buttons": "splitRight"}}}"#)
        #expect(wrongType.map(\.message) == [Self.message])
        let legacy = try diagnostics(#"{"surfaceTabBarButtons": ["splitDown"]}"#)
        #expect(legacy.filter { $0.message == Self.message }.map(\.path) == ["surfaceTabBarButtons"])
    }

    @Test func anUnsetButtonListIsNotReported() throws {
        #expect(try diagnostics("{}").filter { $0.message == Self.message }.isEmpty)
    }
}

/// File on disk -> watcher -> `snapshot.tabBar`, live.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct SurfaceTabBarLiveReloadTests {
    /// Waits for each settings watcher lifecycle event until `condition` holds.
    func eventually(_ controller: SettingsController, line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<20 where !condition() {
            await controller.waitForLoad(atLeast: controller.loadCount + 1)
        }
        #expect(condition(), "line \(line)")
    }

    @Test func buttonsFollowTheFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-next-tabbar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"ui": {"surfaceTabBar": {"buttons": ["cmux.splitRight"]}}}"#.utf8).write(to: url)
        let controller = SettingsController(registry: ActionRegistry.standard(), design: DesignSettings(), fileURL: url)
        controller.start()
        defer { controller.stop() }
        try await eventually(controller) { controller.snapshot.tabBar.buttons.map(\.actionID) == ["splitRight"] }

        try Data(#"{"actions": {"x": {"type": "command", "command": "ls"}}, "ui": {"surfaceTabBar": {"buttons": ["x", "splitDown"]}}}"#.utf8)
            .write(to: url, options: .atomic)
        try await eventually(controller) {
            controller.snapshot.tabBar.buttons.map(\.actionID) == ["cmuxConfig.x", "splitDown"]
                && controller.snapshot.commandActions.map(\.command) == ["ls"]
        }

        try FileManager.default.removeItem(at: url)
        try await eventually(controller) { controller.snapshot.tabBar == .defaults && controller.snapshot.commandActions.isEmpty }
    }
}
