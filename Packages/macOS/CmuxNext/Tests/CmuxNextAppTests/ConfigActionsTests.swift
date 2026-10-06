import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// cmux.json command `actions` -> registry actions (`cmuxConfig.<name>`).
@MainActor
@Suite(.serialized) struct ConfigActionsTests {
    typealias Coverage = ActionBindingCoverageTests

    @Test func configCommandActionsAreRegisteredAndReplaced() throws {
        let services = Coverage.boundServices()
        let controller = services.configActions!
        let command = ConfigCommandAction(name: "start-claude", title: "Start Claude", command: "claude")
        controller.apply([command])
        #expect(services.registry.isBound("cmuxConfig.start-claude"))
        // The action runs through the shared target resolution: an unknown
        // pane is refused, not sent to the focus.
        let outcome = Coverage.run(services, "cmuxConfig.start-claude", target: ActionTargetRef(kind: .pane, id: "p404"))
        guard case .refused = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }

        controller.apply([])
        #expect(!services.registry.isBound("cmuxConfig.start-claude"))
    }

    /// Command actions follow cmux.json live, also the inline command
    /// entries of `ui.surfaceTabBar.buttons` (the strip draws no buttons).
    @Test func commandActionsFollowCmuxJSONLive() async throws {
        let services = Coverage.boundServices()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-next-config-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"actions": {"go": {"type": "command", "command": "ls"}}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url)
        settings.start()
        defer { settings.stop() }
        let controller = services.configActions!
        controller.start(settings: settings)
        defer { controller.stop() }
        try await eventually(settings) { services.registry.isBound("cmuxConfig.go") }

        try Data(#"{"ui": {"surfaceTabBar": {"buttons": [{"command": "make", "id": "build"}]}}}"#.utf8)
            .write(to: url, options: .atomic)
        try await eventually(settings) { services.registry.isBound("cmuxConfig.build") && !services.registry.isBound("cmuxConfig.go") }
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
