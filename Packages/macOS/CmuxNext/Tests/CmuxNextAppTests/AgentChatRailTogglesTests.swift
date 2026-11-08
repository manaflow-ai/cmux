import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The user, 2026-11-03 (msg 20105): a way to hide the chat's edge (the rail of prompt ticks or the
/// minimap) completely, and to choose its left or right edge, each a Cmd+Shift+P row that shows the
/// current state. Show Chat Minimap and Prompt Rail on Right Edge write `agentPane.display.minimap`
/// and `agentPane.display.rail.side`, and each palette row is checked while it is on.
@MainActor @Suite(.serialized) struct AgentChatRailTogglesTests {
    @Test func paletteRowsHideTheMinimapAndMoveTheRailAndShowTheirState() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-chat-rail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()

        let show: ActionID = "agentPane.display.showMinimap"
        let right: ActionID = "agentPane.display.railOnRight"
        for id in [show, right] {
            let descriptor = try #require(services.registry.descriptor(for: id), "\(id) is not in the catalog")
            #expect(descriptor.surfaces.contains(.palette))
            #expect(services.registry.unavailableReason(for: id) == nil, "\(id) is greyed out")
        }
        func checked(_ id: ActionID) -> Bool? { services.registry.action(for: id)?.paletteState?() }
        func saved(_ path: [String]) -> String? {
            guard let data = try? Data(contentsOf: url),
                  var node = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            for key in path.dropLast() { node = node[key] as? [String: Any] ?? [:] }
            return node[path.last ?? ""] as? String
        }
        func until(_ condition: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        }
        let minimap = ["agentPane", "display", "minimap"], side = ["agentPane", "display", "rail", "side"]

        // Defaults: the rail shows, on the left edge.
        #expect(checked(show) == true)
        #expect(checked(right) == false)

        #expect(services.registry.perform(show, invocation: ActionInvocation()))
        await until { saved(minimap) == "off" && checked(show) == false }
        #expect(saved(minimap) == "off")
        #expect(checked(show) == false, "the row still reads as shown after it hid the minimap")
        #expect(services.registry.perform(show, invocation: ActionInvocation()))
        await until { saved(minimap) == nil && checked(show) == true }
        #expect(checked(show) == true)

        #expect(services.registry.perform(right, invocation: ActionInvocation()))
        await until { saved(side) == "right" && checked(right) == true }
        #expect(saved(side) == "right")
        #expect(checked(right) == true)
        #expect(services.registry.perform(right, invocation: ActionInvocation()))
        await until { saved(side) == nil && checked(right) == false }
        #expect(checked(right) == false)
    }
}
