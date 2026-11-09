public import CmuxNextActions
public import CmuxNextDesign

/// A palette row per custom density ("Density: My Tight"), next to the built-ins' catalog rows:
/// checked and marked current while in use; Return runs Set Density with its id.
///
/// ```swift
/// let rows = DensityPaletteRows(currentMark: DensityStrings.current, useTitle: DensityStrings.use)
/// let items = rows.items(design: design, registry: registry)
/// ```
public struct DensityPaletteRows {
    /// The mark after the density in use's title, such as "current".
    public var currentMark: String
    /// The title of a row's Return command, such as "Use Density".
    public var useTitle: String

    /// - Parameters:
    ///   - currentMark: The mark after the density in use's title.
    ///   - useTitle: The title of a row's Return command.
    public init(currentMark: String, useTitle: String) {
        self.currentMark = currentMark
        self.useTitle = useTitle
    }

    /// One row per custom density of `design`, each running `appearance.density.set` on `registry`.
    @MainActor
    public func items(design: DesignSettings, registry: ActionRegistry) -> [PaletteItem] {
        let prefix = DensityActionTitles().prefix
        let currentMark = currentMark, useTitle = useTitle
        return design.customDensities.map { density in
            let current = design.densityTokens == density
            let id = density.id
            var item = PaletteItem(
                id: "density:\(id)",
                title: prefix + density.name + (current ? " (\(currentMark))" : ""),
                symbol: current ? "checkmark.circle.fill" : "slider.vertical.3",
                section: RegistryPaletteProvider.section(for: .settings),
                keywords: ["density", "custom", "size", "spacing", density.name],
                primary: PaletteCommand(id: "run", title: useTitle, symbol: "return", effect: .perform { [weak registry] in
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
