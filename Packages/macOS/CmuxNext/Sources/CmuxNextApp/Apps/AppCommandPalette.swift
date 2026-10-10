import CmuxNextActions
import CmuxNextApps
import CmuxNextPalette
import Foundation

/// `app.command.run`: runs a command an app contributes, or lists the
/// visible apps' commands as a palette page. Commands of hidden or disabled
/// apps never show (the presence rule).
enum AppCommandPalette {
    struct Entry {
        var app: InstalledApp
        var command: AppContribution
    }

    /// Commands of the visible apps that the palette offers (or every
    /// command with `includingNonPalette`, for runs by id).
    @MainActor static func entries(_ registry: AppRegistry, includingNonPalette: Bool = false) -> [Entry] {
        registry.apps.filter(\.isVisible).flatMap { app in
            app.manifest.contributes.of(.command)
                .filter { includingNonPalette || ($0.raw["contexts"]?.arrayValue?.compactMap(\.stringValue) ?? ["palette"]).contains("palette") }
                .filter { $0.raw["x-cmux-devOnly"]?.boolValue != true }
                .map { Entry(app: app, command: $0) }
        }
    }

    /// Root palette items: "Open <App>" for apps with a page, then their commands.
    @MainActor static func rootItems(_ services: AppServices) -> [PaletteItem] {
        let registry = services.apps.registry
        let opens = registry.apps.filter(AppPanePage.opens).map { app in
            let name = app.manifest.name.resolved()
            return PaletteItem(id: "open:\(app.id)", title: AppsAppStrings.open(name), subtitle: name,
                               symbol: "square.grid.2x2", keywords: [app.id, name],
                               primary: PaletteCommand(id: "open", title: AppsAppStrings.run, symbol: "return", effect: .perform {
                                   try? services.apps.openApp(app.id)
                               }))
        }
        return opens + entries(registry).map { item($0, services) }
    }

    @MainActor static func page(_ services: AppServices) -> PalettePageSpec {
        let provider = AsyncPaletteProvider(id: "app.command.run") { [weak services] in
            guard let services else { return [] }
            return entries(services.apps.registry).map { entry in item(entry, services) }
        }
        return PalettePageSpec(id: "app.command.run", title: AppsAppStrings.commandsTitle, placeholder: AppsAppStrings.commandsPlaceholder,
                               symbol: "puzzlepiece.extension", providers: [provider])
    }

    @MainActor private static func item(_ entry: Entry, _ services: AppServices) -> PaletteItem {
        let title = entry.command.title?.resolved() ?? entry.command.id
        let keywords = entry.command.raw["keywords"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return PaletteItem(id: "\(entry.app.id)#\(entry.command.id)", title: title, subtitle: entry.app.manifest.name.resolved(),
                           symbol: entry.command.symbol ?? "puzzlepiece.extension", keywords: keywords + [entry.app.id],
                           primary: PaletteCommand(id: "run", title: AppsAppStrings.run, symbol: "return", effect: .perform {
                               run(entry, services: services)
                           }))
    }

    /// Runs the command in its app (the app's own engine, its own grants).
    @MainActor static func run(_ entry: Entry, services: AppServices, arguments: AppJSON = .object([:])) {
        guard let export = entry.command.export else { return }
        let host = services.apps.host
        let (manifest, directory) = (entry.app.manifest, entry.app.bundle.directory)
        // task-owner: one command run; the app reports failures in its own UI and log.
        Task { _ = await host.runCommand(manifest, directory: directory, export: export, arguments: arguments) }
    }
}
