import CmuxNextActions
import CmuxNextApps
import CmuxNextPalette
import Foundation

/// Hiding apps from the palette (R134): "Hide App" / "Show Hidden Apps" open a
/// picker of the installed apps with their state; Return flips one at once and
/// the palette stays open (the row redraws with its new state, so the same row
/// undoes). Root items "Hide <App>" / "Show <App>" do it in one step. Hidden
/// apps stay reachable from the palette ("Open <App>").
enum AppVisibilityPalette {
    /// The picker; `hiding` lists shown apps first, else hidden apps first.
    @MainActor static func page(_ services: AppServices, hiding: Bool) -> PalettePageSpec {
        let provider = AsyncPaletteProvider(id: hiding ? "app.hide" : "app.unhide") { [weak services] in
            guard let services else { return [] }
            return apps(services.apps.registry, hiddenFirst: !hiding).map { row($0, services) }
        }
        return PalettePageSpec(id: hiding ? "app.hide" : "app.unhide", title: hiding ? AppsAppStrings.hideTitle : AppsAppStrings.showTitle,
                               placeholder: AppsAppStrings.visibilityPlaceholder, symbol: hiding ? "eye.slash" : "eye", providers: [provider])
    }

    /// Installed apps by name, hidden ones first or last.
    @MainActor static func apps(_ registry: AppRegistry, hiddenFirst: Bool) -> [InstalledApp] {
        registry.apps.filter(\.isInstalled).sorted { a, b in
            if a.isHidden != b.isHidden { return a.isHidden == hiddenFirst }
            return a.manifest.name.resolved().localizedCaseInsensitiveCompare(b.manifest.name.resolved()) == .orderedAscending
        }
    }

    /// One picker row: the app with its state; Return flips it, keeping the palette open.
    @MainActor static func row(_ app: InstalledApp, _ services: AppServices) -> PaletteItem {
        let name = app.manifest.name.resolved()
        let hide = !app.isHidden
        var item = PaletteItem(id: "visibility:\(app.id)", title: name,
                               accessory: app.isHidden ? AppsAppStrings.hidden : AppsAppStrings.shown,
                               symbol: symbol(app), keywords: [app.id, "app", "hide", "show"],
                               primary: PaletteCommand(id: "toggle", title: hide ? AppsAppStrings.hide(name) : AppsAppStrings.show(name),
                                                       symbol: hide ? "eye.slash" : "eye",
                                                       effect: .performKeepingOpen { setHidden(app.id, hide, services) }))
        item.actionRefs = [ref(app.id, hide: hide, name: name)]
        return item
    }

    /// Root palette items: "Hide <App>" for shown apps, "Show <App>" for hidden ones.
    @MainActor static func rootItems(_ services: AppServices) -> [PaletteItem] {
        services.apps.registry.apps.filter(\.isInstalled).map { app in
            let name = app.manifest.name.resolved()
            let hide = !app.isHidden
            var item = PaletteItem(id: "\(hide ? "hide" : "show"):\(app.id)", title: hide ? AppsAppStrings.hide(name) : AppsAppStrings.show(name),
                                   subtitle: name, symbol: hide ? "eye.slash" : "eye", keywords: [app.id, name, hide ? "hide" : "show"],
                                   primary: PaletteCommand(id: "run", title: AppsAppStrings.run, symbol: "return", effect: .perform {
                                       setHidden(app.id, hide, services)
                                   }))
            item.actionRefs = [ref(app.id, hide: hide, name: name)]
            return item
        }
    }

    private static func ref(_ id: String, hide: Bool, name: String) -> PaletteActionRef {
        PaletteActionRef(hide ? "app.hide" : "app.unhide", arguments: ["app": .string(id)],
                         title: hide ? AppsAppStrings.hide(name) : AppsAppStrings.show(name))
    }

    private static func symbol(_ app: InstalledApp) -> String {
        if case .symbol(let name)? = app.manifest.icon { return name }
        return "app"
    }

    @MainActor private static func setHidden(_ id: String, _ hidden: Bool, _ services: AppServices) {
        let registry = services.apps.registry
        // task-owner: one visibility change from a palette row; the registry persists it.
        Task { try? await registry.setHidden(id, hidden) }
    }
}
