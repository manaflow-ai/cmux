import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// Settings > Privacy and Security > Send Anonymous Telemetry (`app.sendAnonymousTelemetry`) mirrors
/// the app's `sendAnonymousTelemetry` preference the crash reporter reads at launch (Leo 2026-11-05,
/// ask-9b912a9f8b: "just an option in settings").
@MainActor @Suite(.serialized) struct AnonymousTelemetrySettingTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "cn-telemetry-\(UUID().uuidString)")
    var url: URL { home.appending(path: "cmux-next.json") }
    let key = AnonymousTelemetrySetting.defaultsKey

    func defaults() throws -> UserDefaults {
        let suite = "cn-telemetry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func controller(_ text: String, defaults: UserDefaults, managed: ManagedPreferences = ManagedPreferences()) async throws -> SettingsController {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(managed), managedWatchFiles: [],
                                          telemetryDefaults: defaults)
        await settings.reload()
        return settings
    }

    var descriptor: SettingDescriptor {
        get throws { try #require(SettingsSchema.descriptor(for: AnonymousTelemetrySetting.configPath)) }
    }

    @Test func theRowIsOnByDefaultAndOnlyThePersonMaySetIt() throws {
        let row = try descriptor
        #expect(row.kind == .toggle)
        #expect(row.defaultValue == .bool(true))
        #expect(AnonymousTelemetrySetting().value(in: .object([:])))
        #expect(!SettingsSchema.agentSettableKeys.contains(row.id))
        #expect(row.isPaletteExposed)
        #expect(SettingsSchema.keptOnResetAll.contains(AnonymousTelemetrySetting.configPath), "Reset All never turns sending back on")
    }

    @Test func turningItOffWritesTheDefaultsAndResetRemovesThem() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = try defaults()
        let settings = try await controller("{}", defaults: defaults)

        try await settings.setSetting(try descriptor, to: .bool(false), by: .user)
        #expect(defaults.object(forKey: key) as? Bool == false)
        #expect(try await settings.file.value(at: AnonymousTelemetrySetting.configPath) == .bool(false))

        try await settings.setSetting(try descriptor, to: .bool(true), by: .user)
        #expect(defaults.object(forKey: key) as? Bool == true)

        try await settings.setSetting(try descriptor, to: .bool(false), by: .user)
        try await settings.setSetting(try descriptor, to: nil, by: .user)
        #expect(defaults.object(forKey: key) == nil, "a reset means on, as an unset preference does")
        #expect(try await settings.file.value(at: AnonymousTelemetrySetting.configPath) == nil)
    }

    @Test func anAgentCannotChangeItAndTheDefaultsStay() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = try defaults()
        defaults.set(false, forKey: key)
        let settings = try await controller("{}", defaults: defaults)

        await #expect(throws: SettingUserOnly.self) { try await settings.setSetting(try descriptor, to: .bool(true), by: .caller("mcp")) }
        #expect(defaults.object(forKey: key) as? Bool == false)
    }

    @Test func theLaunchMigrationImportsAnExplicitOff() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = try defaults()
        defaults.set(false, forKey: key)
        let settings = try await controller("{}", defaults: defaults)

        try await settings.importTelemetryConsent()
        #expect(try await settings.file.value(at: AnonymousTelemetrySetting.configPath) == .bool(false))
        #expect(!AnonymousTelemetrySetting().value(in: settings.snapshot.root))
        #expect(defaults.object(forKey: key) as? Bool == false, "never turned back on")
    }

    @Test func theLaunchMigrationWritesNothingForAnUnsetOrOnPreference() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        for stored in [nil, true] as [Bool?] {
            let defaults = try defaults()
            if let stored { defaults.set(stored, forKey: key) }
            let settings = try await controller("{}", defaults: defaults)
            try await settings.importTelemetryConsent()
            #expect(try await settings.file.value(at: AnonymousTelemetrySetting.configPath) == nil)
            #expect(defaults.object(forKey: key) as? Bool == stored)
        }
    }

    @Test func theLaunchMigrationCopiesTheFileIntoTheDefaults() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = try defaults()
        let settings = try await controller(#"{ "app": { "sendAnonymousTelemetry": false } }"#, defaults: defaults)

        try await settings.importTelemetryConsent()
        #expect(defaults.object(forKey: key) as? Bool == false)
    }

    @Test func disableTelemetryLocksTheRowOff() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = try defaults()
        let managed = ManagedPreferences(forced: [AnonymousTelemetrySetting.disableTelemetryPolicyKey: .bool(true)])
        let settings = try await controller(#"{ "app": { "sendAnonymousTelemetry": true } }"#, defaults: defaults, managed: managed)

        #expect(settings.managedKeys[AnonymousTelemetrySetting.key] == .device)
        #expect(!AnonymousTelemetrySetting().value(in: settings.snapshot.root))
        await #expect(throws: SettingManaged.self) { try await settings.setSetting(try descriptor, to: .bool(true), by: .user) }
        try await settings.importTelemetryConsent()
        #expect(defaults.object(forKey: key) == nil, "a managed row leaves the person's own preference alone")
    }

    @Test func disableTelemetryOffLeavesTheRowThePersons() {
        let effective = EffectiveSettings.merge(file: .object([:]), managed: ManagedPreferences(forced: ["DisableTelemetry": .bool(false)]), team: .none)
        #expect(effective.managedKeys[AnonymousTelemetrySetting.key] == nil)
    }
}
