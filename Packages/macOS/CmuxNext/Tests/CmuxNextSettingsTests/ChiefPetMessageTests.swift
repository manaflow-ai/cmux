import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Message the Chief (`home.messageChiefPet`, the palette and a bindable, unbound shortcut): turns the
/// pet on as the person when it is off, then summons it with its reply box open. Person-only like
/// Show Chief Pet: an agent can neither turn the pet on nor put a box that takes the keys over every app.
@MainActor @Suite(.serialized) struct ChiefPetMessageTests {
    @MainActor final class Summons {
        var count = 0
        var enabledThen: [Bool] = []
    }

    static func make() throws -> (ActionRegistry, SettingsController, URL, Summons) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-chief-pet-message-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        let registry = ActionRegistry.standard()
        let summons = Summons()
        HomeChiefPetSetting().bindMessage(into: registry, settings: { settings }, unavailable: "not ready") {
            summons.count += 1
            summons.enabledThen.append(settings.snapshot.homeChiefPetEnabled)
        }
        return (registry, settings, home, summons)
    }

    static func run(_ registry: ActionRegistry, origin: ActionOrigin = .user) async -> [ActionWorkFailure] {
        var failures: [ActionWorkFailure] = []
        let work = registry.capturingWork {
            _ = registry.perform(HomeChiefPetSetting.messageAction, invocation: ActionInvocation(origin: origin))
        }
        for task in work { if let failure = await task.value { failures.append(failure) } }
        return failures
    }

    @Test func theCatalogOffersItInThePaletteAndAsAnUnboundShortcut() throws {
        let descriptor = try #require(ActionRegistry.standard().descriptor(for: HomeChiefPetSetting.messageAction))
        #expect(descriptor.title == "Message the Chief")
        #expect(descriptor.isPaletteVisible)
        #expect(descriptor.surfaces.contains(.keyboard), "bindable in Settings > Keyboard Shortcuts")
        #expect(descriptor.defaultShortcut == nil, "unbound until a default is agreed")
        #expect(descriptor.surfacePlan.cli == .exempt(.guiOnly))
        #expect(descriptor.isPersonOnly)
    }

    /// Off, it summons the pet for this message only: `home.chiefPetEnabled` stays off, in the snapshot
    /// and in cmux-next.json, so a person who never chose the pet does not keep it.
    @Test func offItSummonsThePetAndLeavesTheStoredValueOff() async throws {
        let (registry, settings, home, summons) = try Self.make()
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        #expect(await Self.run(registry).isEmpty)
        #expect(summons.count == 1)
        #expect(settings.snapshot.homeChiefPetEnabled == false)
        let stored = try String(contentsOf: home.appending(path: "cmux-next.json"), encoding: .utf8)
        #expect(!stored.contains("chiefPetEnabled"), "nothing written: \(stored)")
    }

    @Test func onItSummonsAtOnceAndLeavesTheSettingAlone() async throws {
        let (registry, settings, home, summons) = try Self.make()
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        try await settings.setSetting(at: HomeChiefPetSetting.configPath, to: .bool(true), by: SettingWriter(.user))
        #expect(await Self.run(registry).isEmpty)
        #expect(summons.count == 1)
        #expect(settings.snapshot.homeChiefPetEnabled)
    }

    @Test func aRunRightAfterHideChiefPetWaitsForItAndTurnsThePetBackOn() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-chief-pet-message-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: "cmux-next.json")
        try Data(#"{"home": {"chiefPetEnabled": true}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        #expect(settings.snapshot.homeChiefPetEnabled)
        let registry = ActionRegistry.standard()
        let summons = Summons()
        let toggles = ChiefPetToggles()
        HomeChiefPetSetting().bind(into: registry, settings: { settings }, unavailable: "not ready", toggles: toggles)
        HomeChiefPetSetting().bindMessage(into: registry, settings: { settings }, unavailable: "not ready", toggles: toggles) {
            summons.count += 1
            summons.enabledThen.append(settings.snapshot.homeChiefPetEnabled)
        }
        var failures: [ActionWorkFailure] = []
        let work = registry.capturingWork {
            _ = registry.perform(HomeChiefPetSetting.toggleAction, invocation: ActionInvocation(origin: .user))
            _ = registry.perform(HomeChiefPetSetting.messageAction, invocation: ActionInvocation(origin: .user))
        }
        for task in work { if let failure = await task.value { failures.append(failure) } }
        #expect(failures.isEmpty)
        #expect(settings.snapshot.homeChiefPetEnabled, "the newer command, Message the Chief, wins")
        #expect(summons.enabledThen == [true], "summoned once, after both writes landed")
    }

    @Test func anAgentCannotSummonThePet() async throws {
        let (registry, settings, home, summons) = try Self.make()
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        let refusal = registry.capturingRefusal {
            _ = registry.perform(HomeChiefPetSetting.messageAction, invocation: ActionInvocation(origin: .mcp))
        }
        #expect(refusal?.contains("home.chiefPetEnabled") == true, "the settings layer's user-only words, not Home not ready")
        #expect(summons.count == 0)
        #expect(settings.snapshot.homeChiefPetEnabled == false)
    }
}
