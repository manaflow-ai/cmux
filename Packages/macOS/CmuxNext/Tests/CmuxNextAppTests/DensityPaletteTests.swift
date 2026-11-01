import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPalette
import Testing

/// Lawrence 2026-10-20 (Cmd-Shift-P, "compact"): "Sidebar Density: Compact" and "Use Compact
/// Density" both showed, and "this option doesnt really make sense i press enter and nothign
/// happens". Now one row per density ("Density: Compact (current)", checked), Return applies it
/// at once, and choosing the one in use says so. Custom densities get rows too.
@MainActor @Suite(.serialized)
struct DensityPaletteTests {
    final class Notes { var messages: [String] = [] }

    struct Fixture {
        let services: AppServices
        let design: DesignSettings
        let notes: Notes
        var registry: ActionRegistry { services.registry }
    }

    /// The app's actions, with the density ones on a design of their own (not the app-wide one).
    static func fixture() -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        var context = AppActionContext(services: services)
        let design = DesignSettings()
        context.design = design
        let notes = Notes()
        DensityHandlers.bind(into: services.registry, context: context,
                             controller: DensityController(context: context) { notes.messages.append($0) })
        return Fixture(services: services, design: design, notes: notes)
    }

    @Test func returnOnARowAppliesItsDensityAtOnce() {
        let f = Self.fixture()
        for preset in DensityPreset.allCases.reversed() {
            #expect(f.registry.perform(ActionID(rawValue: "appearance.density.\(preset.rawValue)")))
            #expect(f.design.densityTokens == preset.tokens, "\(preset)")
        }
        #expect(f.notes.messages.isEmpty, "a change is its own feedback")
    }

    @Test func choosingTheDensityInUseSaysSo() {
        let f = Self.fixture()
        _ = f.registry.perform("appearance.density.compact")
        #expect(f.design.densityTokens == .compact)
        #expect(f.notes.messages.count == 1)
        #expect(f.notes.messages.first?.contains("Compact") == true, "\(f.notes.messages)")
    }

    @Test func theRowInUseIsCheckedAndMarkedCurrent() throws {
        let f = Self.fixture()
        let compact = try #require(f.registry.action(for: "appearance.density.compact"))
        #expect(compact.paletteState?() == true)
        #expect(compact.paletteTitle?()?.hasSuffix("(current)") == true)
        _ = f.registry.perform("appearance.density.cozy")
        #expect(f.registry.action(for: "appearance.density.compact")?.paletteState?() == false)
        #expect(f.registry.action(for: "appearance.density.compact")?.paletteTitle?() == nil)
        #expect(f.registry.action(for: "appearance.density.cozy")?.paletteState?() == true)
    }

    /// Compact Workspace List (`sidebar.compactList.toggle`, #27883) is the DEV-only one-line workspace
    /// list, not a density, so it is not a second Compact density row.
    @Test func onePaletteRowSaysCompact() {
        let f = Self.fixture()
        let titles = RegistryPaletteProvider(registry: f.registry).makeItems()
            .filter { $0.id != "action:sidebar.compactList.toggle" }.map(\.title).filter { $0.contains("Compact") }
        #expect(titles == ["Density: Compact (current)"], "\(titles)")
        let densityRows = RegistryPaletteProvider(registry: f.registry).makeItems().map(\.title).filter { $0.hasPrefix("Density: ") }
        #expect(densityRows.count == DensityPreset.allCases.count, "\(densityRows)")
    }

    @Test func aCustomDensityIsMadeUsedAndListed() throws {
        let f = Self.fixture()
        let made = f.registry.perform("appearance.density.create",
                                      invocation: ActionInvocation(arguments: ["name": .string("My Tight"), "basedOn": .string("ultraCompact"),
                                                                               "fontSize": .string("11")]))
        #expect(made)
        let custom = try #require(f.design.customDensities.first)
        #expect(custom.id == "my-tight" && custom.basedOn == "ultraCompact" && custom.fontSize == 11)
        #expect(f.design.densityTokens == custom)
        _ = f.registry.perform("appearance.density.spacious")
        let rows = DensityPaletteRows.items(design: f.design, registry: f.registry)
        let row = try #require(rows.first)
        #expect(rows.count == 1 && row.title == "Density: My Tight")
        guard case .perform(let run) = row.primary.effect else { Issue.record("the row runs Set Density"); return }
        run()
        #expect(f.design.densityTokens == custom)
        #expect(DensityPaletteRows.items(design: f.design, registry: f.registry).first?.title == "Density: My Tight (current)")
    }

    @Test func setDensityTakesAnyIDAndRefusesAnUnknownOne() {
        let f = Self.fixture()
        _ = f.registry.perform("appearance.density.set", invocation: ActionInvocation(arguments: ["density": .string("comfortable")]))
        #expect(f.design.densityTokens == DensityPreset.comfortable.tokens)
        _ = f.registry.perform("appearance.density.set", invocation: ActionInvocation(arguments: ["density": .string("nope")]))
        #expect(f.design.densityTokens == DensityPreset.comfortable.tokens)
        let ids = f.registry.argumentSuggestions?(ActionSuggestions.densities).map(\.value) ?? []
        #expect(ids == DensityPreset.allCases.map(\.rawValue))
    }

    @Test func theCLIHasDensitySetAndCreate() {
        let f = Self.fixture()
        #expect(f.registry.descriptor(for: "appearance.density.set")?.cliName == "density set")
        #expect(f.registry.descriptor(for: "appearance.density.create")?.cliName == "density create")
        #expect(f.registry.descriptor(for: "sidebar.density.compact")?.surfaces.contains(.palette) == false)
    }
}
