import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// Lawrence 2026-11-09: "move all debug things to cmd shift p that is only visible when cmux internal
/// developer mode is toggled on". Every debug-only action is a Command Palette row titled "Debug: <name>",
/// listed only while Internal Developer Mode is on, and only in a build with developer tools (DEV, NIGHTLY).
@MainActor
@Suite struct DebugActionsPaletteOnlyTests {
    /// The full catalog, every action bound and every context fact present, behind `gate`.
    private static func registry(_ gate: DebugActionGate) -> ActionRegistry {
        let registry = ActionRegistry.standard()
        for descriptor in registry.descriptors {
            registry.context.formUnion(descriptor.requires)
            registry.bindEffect(descriptor.id) { _ in .done }
        }
        registry.debugActions = gate
        return registry
    }

    private static var debugIDs: Set<ActionID> {
        Set(ActionCatalog.all.filter { $0.isDebugOnly && $0.isPaletteVisible }.map(\.id))
    }

    /// The debug-only rows a palette open lists, in its order.
    private static func debugRows(_ provider: RegistryPaletteProvider) -> [PaletteItem] {
        provider.makeItems().filter { $0.actionID.map(debugIDs.contains) == true }
    }

    private static let devBuild = DevTools.isAvailable(bundleID: "com.cmuxterm.app.debug.issues", isDebugBuild: true)
    private static let releaseBuild = DevTools.isAvailable(bundleID: "com.cmuxterm.app", isDebugBuild: false)

    @Test func debugActionsAreAbsentWhileInternalDeveloperModeIsOff() {
        #expect(!Self.debugIDs.isEmpty)
        let registry = Self.registry(DebugActionGate(devTools: Self.devBuild, isOn: { false }))
        #expect(Self.debugRows(RegistryPaletteProvider(registry: registry)).isEmpty)
        #expect(!registry.isAvailable("openDebugSettings"), "a key press does not reach a debug action either")
    }

    @Test func debugActionsAreDebugRowsWhileItIsOn() {
        let registry = Self.registry(DebugActionGate(devTools: Self.devBuild, isOn: { true }))
        let rows = Self.debugRows(RegistryPaletteProvider(registry: registry))
        #expect(Set(rows.compactMap(\.actionID)) == Self.debugIDs)
        let prefix = String(format: DebugActionGate.titleFormat, "")
        for row in rows { #expect(row.title.hasPrefix(prefix), "\(row.title)") }
        let titles = rows.map(\.title)
        #expect(titles == titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "sorted by name: \(titles)")
    }

    @Test func aReleaseBuildNeverListsThemEvenWithTheToggleOn() {
        #expect(!Self.releaseBuild)
        let registry = Self.registry(DebugActionGate(devTools: Self.releaseBuild, isOn: { true }))
        #expect(Self.debugRows(RegistryPaletteProvider(registry: registry)).isEmpty)
    }

    @Test func aToggleChangeShowsAtTheNextPaletteOpen() throws {
        var on = false
        let registry = Self.registry(DebugActionGate(devTools: Self.devBuild, isOn: { on }))
        let palette = PaletteController(registry: registry, sources: PaletteSources(), frecencyPersistence: nil)
        let provider = try #require(palette.commandsPage().providers.first as? RegistryPaletteProvider)
        #expect(Self.debugRows(provider).isEmpty)
        on = true
        #expect(Set(Self.debugRows(provider).compactMap(\.actionID)) == Self.debugIDs)
        on = false
        #expect(Self.debugRows(provider).isEmpty)
    }

    /// Debug-only actions live in the palette alone: no main-menu placement, no menu or context-menu surface.
    @Test func debugActionsHaveNoMenuPlacement() {
        for descriptor in ActionCatalog.all where descriptor.isDebugOnly {
            #expect(descriptor.mainMenu == nil, "\(descriptor.id)")
            #expect(!descriptor.surfaces.contains(.menu) && !descriptor.surfaces.contains(.contextMenu), "\(descriptor.id)")
            #expect(descriptor.surfaces.contains(.palette), "\(descriptor.id)")
        }
    }
}
