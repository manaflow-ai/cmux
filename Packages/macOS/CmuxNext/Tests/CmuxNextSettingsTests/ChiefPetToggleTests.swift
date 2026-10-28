import CmuxNextActions
import CmuxNextAppearance
@testable import CmuxNextSettings
import Foundation
import Testing

/// Show Chief Pet / Hide Chief Pet (`home.toggleChiefPet`): the View menu item and palette row
/// flip `home.chiefPetEnabled` and read as the change they make. It is person-only with no CLI
/// verb (the control socket refuses an agent's run); an agent sets the key itself instead.
@MainActor @Suite(.serialized) struct ChiefPetToggleTests {
    static func make(managed: ManagedPreferences = ManagedPreferences()) throws -> (ActionRegistry, SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-chief-pet-toggle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(managed), managedWatchFiles: [])
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

    /// `home.chiefPetEnabled` is agent-settable (ChiefPetSettingTests), so a write as an agent
    /// lands; the toggle itself stays person-only at the control socket (`isPersonOnly` above).
    @Test func anAgentOriginWriteTurnsThePetOn() async throws {
        let (registry, settings, home) = try Self.make()
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        #expect(await Self.run(registry, origin: .mcp).isEmpty)
        #expect(settings.snapshot.homeChiefPetEnabled)
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

    /// The pet's Hide passes `on: false`: it only turns the pet off, even when a second Hide arrives
    /// before the first write lands (the pet still on screen), where a flip would turn it back on.
    @Test func hideWithOnFalseNeverTurnsThePetOn() async throws {
        let (registry, settings, home) = try Self.make()
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        #expect(await Self.run(registry).isEmpty)
        #expect(settings.snapshot.homeChiefPetEnabled)
        let hide = ActionInvocation(arguments: ["on": .bool(false)], origin: .user)
        let work = registry.capturingWork {
            _ = registry.perform(HomeChiefPetSetting.toggleAction, invocation: hide)
            _ = registry.perform(HomeChiefPetSetting.toggleAction, invocation: hide)
        }
        for task in work { #expect(await task.value == nil) }
        #expect(settings.snapshot.homeChiefPetEnabled == false)
        for task in registry.capturingWork({ _ = registry.perform(HomeChiefPetSetting.toggleAction, invocation: hide) }) {
            #expect(await task.value == nil)
        }
        #expect(settings.snapshot.homeChiefPetEnabled == false, "a Hide while off leaves it off")
    }

    /// A managed `home.chiefPetEnabled` cannot change, so the toggle (the View menu, the palette and
    /// the pet's Hide) is disabled and a run does nothing.
    @Test func aManagedSettingDisablesTheToggle() async throws {
        let (registry, settings, home) = try Self.make(managed: ManagedPreferences(forced: ["home.chiefPetEnabled": .bool(true)]))
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        let action = try #require(registry.action(for: HomeChiefPetSetting.toggleAction))
        #expect(action.isEnabled() == false)
        #expect(await Self.run(registry).isEmpty)
        #expect(settings.snapshot.homeChiefPetEnabled, "the managed value stays")
    }
}
