import CmuxNextActions
import CmuxNextDesign
import CmuxNextPalette

/// A palette row per custom density ("Density: My Tight"), next to the built-ins' catalog rows:
/// checked and marked current while in use; Return runs Set Density with its id.
enum DensityPaletteRows {
    static func items(design: DesignSettings, registry: ActionRegistry) -> [PaletteItem] {
        let prefix = DensityActionTitles().prefix
        return design.customDensities.map { density in
            let current = design.densityTokens == density
            let id = density.id
            var item = PaletteItem(
                id: "density:\(id)",
                title: prefix + density.name + (current ? " (\(DensityStrings.current))" : ""),
                symbol: current ? "checkmark.circle.fill" : "slider.vertical.3",
                section: RegistryPaletteProvider.section(for: .settings),
                keywords: ["density", "custom", "size", "spacing", density.name],
                primary: PaletteCommand(id: "run", title: DensityStrings.use, symbol: "return", effect: .perform { [weak registry] in
                    _ = registry?.perform("appearance.density.set", invocation: ActionInvocation(arguments: ["density": .string(id)]))
                }),
                frecencyKey: "density:\(id)",
                actionID: "appearance.density.set"
            )
            item.actionRefs = [PaletteActionRef("appearance.density.set", arguments: ["density": .string(id)])]
            return item
        }
    }
}
