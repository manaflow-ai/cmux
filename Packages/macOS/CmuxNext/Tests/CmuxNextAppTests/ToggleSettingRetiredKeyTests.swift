import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Toggle Setting (palette, `cmux settings toggle-setting`) never writes a retired key. A retired key
/// has no descriptor, so the handler's raw write for keys outside the schema used to set it again
/// (`labs.classicHome`, retired after the docked Home); `SettingsController.set` now refuses it.
@MainActor @Suite(.serialized) struct ToggleSettingRetiredKeyTests {
    func make() async throws -> (services: AppServices, url: URL) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-toggle-retired-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        return (services, url)
    }

    /// The value at `path` in cmux.json now.
    func saved(_ url: URL, _ path: [String]) -> Any? {
        guard let data = try? Data(contentsOf: url), var node = try? JSONSerialization.jsonObject(with: data) else { return nil }
        for key in path {
            guard let object = node as? [String: Any], let next = object[key] else { return nil }
            node = next
        }
        return node
    }

    func toggle(_ services: AppServices, _ key: String) {
        _ = services.registry.perform("palette.toggleSetting", invocation: ActionInvocation(arguments: ["setting": .string(key), "on": .bool(true)], origin: .user))
    }

    @Test func aRetiredKeyIsNotWritten() async throws {
        #expect(SettingsSchema.isRetired(["labs", "classicHome"]))
        let (services, url) = try await make()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Both toggles' writes, as a capturing caller (`action.run`) awaits them: each one has applied or
        // been refused when its task ends. A key outside the schema still takes the raw write.
        let work = services.registry.capturingWork {
            toggle(services, "labs.classicHome")
            toggle(services, "test.toggleSettingProbe")
        }
        #expect(work.count >= 2, "each toggle reports its write")
        for task in work { _ = await task.value }
        #expect(saved(url, ["test", "toggleSettingProbe"]) as? Bool == true)
        #expect(saved(url, ["labs", "classicHome"]) == nil, "toggle-setting wrote the retired key labs.classicHome")
    }
}
