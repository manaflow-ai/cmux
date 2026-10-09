import CmuxNextActions
import CmuxNextApps
import CmuxNextPalette
import Foundation

/// `app.command.run`: runs a command an app contributes (a catalog op of the
/// app's own family on the palette surface, `apps-list` `commands`), or
/// lists the presented apps' commands as a palette page. Commands of hidden
/// or disabled apps never show (the presence rule). The app supervisor runs
/// the op (`apps-run`).
enum AppCommandPalette {
    struct Entry {
        var app: AppRecord
        var command: AppRecord.Command

        /// `command` names this entry: the full op (`coderouter.app.connect_account`),
        /// or the last segment in either case style (`connect_account`, `connectAccount`).
        func matches(_ command: String) -> Bool {
            let op = self.command.op
            if op == command { return true }
            let last = op.split(separator: ".").last.map(String.init) ?? op
            return last == command || last == Self.snakeCase(command)
        }

        static func snakeCase(_ name: String) -> String {
            name.reduce(into: "") { out, character in
                if character.isUppercase, !out.isEmpty { out.append("_") }
                out.append(Character(character.lowercased()))
            }
        }
    }

    /// Commands an invocation from `origin` may run: the palette (user)
    /// reaches presented apps only; the CLI, MCP and automations also reach a
    /// hidden app whose `hidden_access` allows that channel (V9).
    @MainActor static func entries(_ apps: AppsService, origin: ActionOrigin = .user) -> [Entry] {
        let presence = apps.presence
        return apps.client.apps.filter { reaches($0, origin: origin, presented: presence.isPresented($0.id)) }.flatMap { app in
            app.commands.map { Entry(app: app, command: $0) }
        }
    }

    /// Whether a run from `origin` reaches `app` (pure, for tests).
    nonisolated static func reaches(_ app: AppRecord, origin: ActionOrigin, presented: Bool) -> Bool {
        if presented { return true }
        guard app.isActive, app.hidden else { return false }
        switch origin {
        case .cli: return app.hiddenAccess.cli
        case .mcp: return app.hiddenAccess.mcp
        case .script, .remote: return app.hiddenAccess.automations
        default: return false
        }
    }

    /// Root palette items: "Open <App>" for apps with a page, then their commands.
    @MainActor static func rootItems(_ services: AppServices) -> [PaletteItem] {
        let presence = services.apps.presence
        let opens = services.apps.client.apps.filter { presence.isPresented($0.id) && AppPanePage.opens($0) }.map { app in
            let name = app.manifest.name.resolved()
            return PaletteItem(id: "open:\(app.id)", title: AppsAppStrings.open(name), subtitle: name,
                               symbol: "square.grid.2x2", keywords: [app.id, name],
                               primary: PaletteCommand(id: "open", title: AppsAppStrings.run, symbol: "return", effect: .perform {
                                   _ = services.registry.perform("app.open", invocation: ActionInvocation(arguments: ["app": .string(app.id)],
                                                                                                          origin: .user))
                               }))
        }
        return opens + entries(services.apps).map { item($0, services) }
    }

    @MainActor static func page(_ services: AppServices) -> PalettePageSpec {
        let provider = AsyncPaletteProvider(id: "app.command.run") { [weak services] in
            guard let services else { return [] }
            return entries(services.apps).map { entry in item(entry, services) }
        }
        return PalettePageSpec(id: "app.command.run", title: AppsAppStrings.commandsTitle, placeholder: AppsAppStrings.commandsPlaceholder,
                               symbol: "puzzlepiece.extension", providers: [provider])
    }

    @MainActor private static func item(_ entry: Entry, _ services: AppServices) -> PaletteItem {
        PaletteItem(id: "\(entry.app.id)#\(entry.command.op)", title: entry.command.title.resolved(), subtitle: entry.app.manifest.name.resolved(),
                    symbol: "puzzlepiece.extension", keywords: [entry.app.id, entry.command.op],
                    primary: PaletteCommand(id: "run", title: AppsAppStrings.run, symbol: "return", effect: .perform {
                        // The one run path (`app.command.run`): its failure reaches the user like every action's.
                        _ = services.registry.perform("app.command.run", invocation: ActionInvocation(
                            arguments: ["app": .string(entry.app.id), "command": .string(entry.command.op)], origin: .user))
                    }))
    }

    /// Runs the command in its app with the caller's origin (the supervisor
    /// runs the op with the app's grants). The work's failure is the action's
    /// failure: the CLI and the palette report the real result.
    @MainActor static func run(_ entry: Entry, services: AppServices, origin: ActionOrigin, arguments: AppJSON = .object([:])) -> ActionWork {
        let client = services.apps.client
        let appOrigin = AppOrigin(rawValue: origin.rawValue) ?? .script
        return Task { @MainActor in
            do throws(AppsClientError) {
                _ = try await client.run(app: entry.app.id, op: entry.command.op, args: arguments, origin: appOrigin)
                return nil
            } catch {
                return ActionWorkFailure(error.description)
            }
        }
    }
}
