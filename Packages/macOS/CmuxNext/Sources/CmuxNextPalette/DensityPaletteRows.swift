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

    /// Binds each built-in's catalog row (`appearance.density.<id>`): Return runs `apply` with its id, and the row is
    /// checked and titled "… (current)" while that density is in use.
    @MainActor
    public func bindPresets(into registry: ActionRegistry, design: DesignSettings, apply: @escaping @MainActor (String) throws -> Void) {
        let currentMark = currentMark
        for preset in DensityPreset.allCases {
            let id = ActionID(rawValue: "appearance.density.\(preset.rawValue)")
            // Applying is a local settings change: it shows in this turn, nothing waits on a reply.
            registry.bindEffect(id, effect: { _ in
                do { try apply(preset.rawValue) } catch { return .refused("\(error)") }
                return .done
            })
            ActionTargetTitles.setPaletteState(id, in: registry) { design.densityTokens.id == preset.rawValue }
            ActionTargetTitles.setPaletteTitle(id, in: registry) { [weak registry] in
                guard design.densityTokens.id == preset.rawValue, let title = registry?.descriptor(for: id)?.title else { return nil }
                return "\(title) (\(currentMark))"
            }
        }
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

    /// The Density Playground's row ("Density Playground"): Return opens the playground, where every density value
    /// tunes live and new densities are made. Shown when the query matches it (density, playground, tune, spacing).
    /// - Parameters:
    ///   - title: The row's title.
    ///   - open: Opens the playground.
    @MainActor
    public static func playground(title: String, open: @escaping @MainActor () -> Void) -> PaletteItem {
        PaletteItem(
            id: "density:playground",
            title: title,
            symbol: "slider.vertical.3",
            section: RegistryPaletteProvider.section(for: .settings),
            keywords: ["density", "playground", "tune", "tuner", "spacing", "padding", "size", "tabs", "vertical", "horizontal", "custom"],
            primary: PaletteCommand(id: "run", title: title, symbol: "return", effect: .perform { open() }),
            frecencyKey: "density:playground"
        )
    }
}
