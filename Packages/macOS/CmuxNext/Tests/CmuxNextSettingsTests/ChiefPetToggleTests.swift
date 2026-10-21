import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Show Chief Pet / Hide Chief Pet (`home.toggleChiefPet`): the View menu item and palette row
/// flip `home.chiefPetEnabled` and read as the change they make. It is person-only with no CLI
/// verb, and an agent cannot turn the pet on.
@MainActor @Suite(.serialized) struct ChiefPetToggleTests {
    static func make() throws -> (ActionRegistry, SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-chief-pet-toggle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        let registry = ActionRegistry.standard()
        HomeChiefPetSetting().bind(into: registry, settings: { settings }, unavailable: "not ready")
        return (registry, settings, home)
    }

    static func run(_ registry: ActionRegistry, origin: ActionOrigin = .user) async -> [ActionWorkFailure] {
        var failures: [ActionWorkFailure] = []
        let work = registry.capturingWork {
            _ = registry.perform(HomeChiefPetSetting.toggleAction, invocation: ActionInvocation(origin: origin))
        }
        for task in work { if let failure = await task.value { failures.append(failure) } }
        return failures
    }

    @Test func theCatalogPutsItInTheViewMenuAndThePalette() throws {
        let descriptor = try #require(ActionRegistry.standard().descriptor(for: HomeChiefPetSetting.toggleAction))
        #expect(descriptor.title == "Show Chief Pet")
        #expect(descriptor.mainMenu == .view)
        #expect(descriptor.isPaletteVisible)
        #expect(descriptor.surfacePlan.cli == .exempt(.guiOnly), "user-only setting: a CLI run would always be refused")
        #expect(descriptor.isPersonOnly, "the control socket refuses it, whatever origin it claims")
    }

    @Test func eachRunFlipsThePetAndTheTitleNamesTheChange() async throws {
        let (registry, settings, home) = try Self.make()
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        let action = try #require(registry.action(for: HomeChiefPetSetting.toggleAction))
        #expect(settings.snapshot.homeChiefPetEnabled == false)
        #expect(action.paletteTitle?() == nil, "off: the catalog's Show Chief Pet")

        #expect(await Self.run(registry).isEmpty)
        #expect(settings.snapshot.homeChiefPetEnabled)
        #expect(action.paletteTitle?() == "Hide Chief Pet")
        #expect(action.targetTitle?(ActionInvocation()) == "Hide Chief Pet")

        #expect(await Self.run(registry).isEmpty)
        #expect(settings.snapshot.homeChiefPetEnabled == false)
        #expect(action.targetTitle?(ActionInvocation()) == nil)
    }

    @Test func anAgentCannotTurnThePetOn() async throws {
        let (registry, settings, home) = try Self.make()
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        let failures = await Self.run(registry, origin: .mcp)
        #expect(failures.count == 1)
        #expect(settings.snapshot.homeChiefPetEnabled == false)
    }

    /// Two runs before the first write lands (a double-click on the menu item): the second flips
    /// the first's value, not the stale snapshot, so the pet ends as it began.
    @Test func twoQuickRunsPutThePetBack() async throws {
        let (registry, settings, home) = try Self.make()
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        let action = try #require(registry.action(for: HomeChiefPetSetting.toggleAction))
        var titleInFlight: String?
        let work = registry.capturingWork {
            _ = registry.perform(HomeChiefPetSetting.toggleAction, invocation: ActionInvocation(origin: .user))
            titleInFlight = action.paletteTitle?()
            _ = registry.perform(HomeChiefPetSetting.toggleAction, invocation: ActionInvocation(origin: .user))
        }
        #expect(titleInFlight == "Hide Chief Pet", "the row names the change in flight")
        #expect(work.count == 2)
        var failures = 0
        for task in work { if await task.value != nil { failures += 1 } }
        #expect(failures == 0)
        #expect(settings.snapshot.homeChiefPetEnabled == false)
        #expect(action.paletteTitle?() == nil)
    }
}
