import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextSettingsWindow
import CmuxNextSidebar
import CmuxNextTabs

/// Binds the density actions (DensityActionCatalog) to one ``DensityController``: each built-in's
/// palette row ("Density: Compact", checked and marked current while in use), Set Density and New
/// Custom Density, the `densities` argument list, and a palette row per custom density.
enum DensityHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext, controller: DensityController? = nil) {
        let controller = controller ?? DensityController(context: context)
        let design = context.design
        let rows = DensityPaletteRows(currentMark: DensityStrings.current, useTitle: DensityStrings.use)
        rows.bindPresets(into: registry, design: design) { try controller.apply(id: $0) }
        registry.bind("appearance.density.set", run: { invocation in
            try controller.apply(id: invocation["density"]?.stringValue ?? "")
        })
        registry.bind("appearance.density.create", run: { invocation in
            let size = invocation["fontSize"]?.stringValue.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            try controller.create(name: invocation["name"]?.stringValue ?? "", basedOn: invocation["basedOn"]?.stringValue, fontSize: size)
        })
        let others = registry.argumentSuggestions
        registry.argumentSuggestions = { $0 == ActionSuggestions.densities ? controller.choices() : others?($0) ?? [] }
        let playground = DensityPlaygroundWindow(model: DensityPlaygroundModel(entries: DensityTokenCatalog.entries(fallbacks: [
            SidebarRowTuning.densityFallbacks, VerticalTabListMetrics.densityFallbacks, OmnibarMetrics.densityFallbacks]), design: design, isManaged: { (try? controller.requireUnmanaged()) == nil }, persist: controller.persist(customs:active:)))
        let row = DensityPaletteRows.playground(title: DensityPlaygroundStrings.title, open: { playground.show() })
        context.services.palette.sources.extraProviders.append(AsyncPaletteProvider(id: "densities", showsItemsForEmptyQuery: false) {
            [weak registry] in [row] + (registry.map { rows.items(design: design, registry: $0) } ?? [])
        })
    }
}
