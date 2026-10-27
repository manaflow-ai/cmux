import CmuxNextActions
import Foundation
import CmuxNextDesign
import CmuxNextPalette
import CmuxNextSettings

/// Binds the density actions (DensityActionCatalog) to one ``DensityController``: each built-in's
/// palette row ("Density: Compact", checked and marked current while in use), Set Density and New
/// Custom Density, the `densities` argument list, and a palette row per custom density.
enum DensityHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext, controller: DensityController? = nil) {
        let controller = controller ?? DensityController(context: context)
        let design = context.design
        for preset in DensityPreset.allCases {
            let id = ActionID(rawValue: "appearance.density.\(preset.rawValue)")
            registry.bind(id, run: { _ in try controller.apply(id: preset.rawValue) })
            ActionTargetTitles.setPaletteState(id, in: registry) { design.densityTokens.id == preset.rawValue }
            ActionTargetTitles.setPaletteTitle(id, in: registry) { [weak registry] in
                guard design.densityTokens.id == preset.rawValue, let title = registry?.descriptor(for: id)?.title else { return nil }
                return "\(title) (\(DensityStrings.current))"
            }
        }
        registry.bind("appearance.density.set", run: { invocation in
            try controller.apply(id: invocation["density"]?.stringValue ?? "")
        })
        registry.bind("appearance.density.create", run: { invocation in
            let size = invocation["fontSize"]?.stringValue.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            try controller.create(name: invocation["name"]?.stringValue ?? "", basedOn: invocation["basedOn"]?.stringValue, fontSize: size)
        })
        let others = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            source == ActionSuggestions.densities ? controller.choices() : others?(source) ?? []
        }
        context.services.palettes.sources.extraProviders.append(AsyncPaletteProvider(id: "densities", showsItemsForEmptyQuery: false) {
            [weak registry] in registry.map { DensityPaletteRows.items(design: design, registry: $0) } ?? []
        })
    }
}
