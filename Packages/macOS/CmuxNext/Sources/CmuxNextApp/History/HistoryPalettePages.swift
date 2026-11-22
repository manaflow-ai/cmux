import CmuxAgentBrands
import CmuxNextHistory
import CmuxNextPalette
import Foundation

/// Palette pages over history (plans/cmux-next/history.md 5.2): Search
/// History (every kind), Location History, Recently Closed, Resume Agent
/// Session. Rows carry the same actions as the history page.
@MainActor
enum HistoryPalettePages {
    static func search(_ services: AppServices) -> PalettePageSpec {
        page(services, id: "history.search", title: HistoryAppStrings.searchTitle, placeholder: HistoryAppStrings.searchPlaceholder,
             symbol: "clock", kinds: [])
    }

    static func locations(_ services: AppServices) -> PalettePageSpec {
        page(services, id: "history.locations", title: HistoryAppStrings.locationsTitle,
             placeholder: HistoryAppStrings.locationsPlaceholder, symbol: "clock", kinds: [.location])
    }

    static func closed(_ services: AppServices) -> PalettePageSpec {
        page(services, id: "history.closed", title: HistoryAppStrings.closedTitle, placeholder: HistoryAppStrings.closedPlaceholder,
             symbol: "clock.arrow.circlepath", kinds: [.closed])
    }

    static func commands(_ services: AppServices) -> PalettePageSpec {
        page(services, id: "history.commands", title: HistoryAppStrings.commandsTitle,
             placeholder: HistoryAppStrings.commandsPlaceholder, symbol: "terminal", kinds: [.command])
    }

    static func agents(_ services: AppServices) -> PalettePageSpec {
        page(services, id: "history.agents", title: HistoryAppStrings.agentsTitle, placeholder: HistoryAppStrings.agentsPlaceholder,
             symbol: "arrow.clockwise.circle", kinds: [.agent])
    }

    private static func page(_ services: AppServices, id: String, title: String, placeholder: String, symbol: String,
                             kinds: Set<HistoryEntry.Kind>) -> PalettePageSpec {
        let provider = AsyncPaletteProvider(id: id) { [weak services] in
            guard let services else { return [] }
            let entries = await services.history.entries(HistoryQuery(kinds: kinds, limit: 500))
            return entries.map { item(for: $0, services: services) }
        }
        return PalettePageSpec(id: id, title: title, placeholder: placeholder, symbol: symbol, providers: [provider])
    }

    /// The brand mark an agent session's row draws (its provider's), or nil.
    nonisolated static func agentBrand(_ entry: HistoryEntry) -> String? {
        guard case .agent(let session) = entry.payload else { return nil }
        return AgentBrandCatalog.brand(for: session.provider)?.rawValue
    }

    static func item(for entry: HistoryEntry, services: AppServices) -> PaletteItem {
        let restorer = HistoryRestorer(services: services)
        var secondary: [PaletteCommand] = []
        var accessory = RelativeDateTimeFormatter().localizedString(for: entry.time, relativeTo: Date())
        let primaryTitle: String
        switch entry.payload {
        case .page(let url, _):
            primaryTitle = HistoryAppStrings.open
            secondary.append(PaletteCommand(id: "newTab", title: HistoryAppStrings.openInNewTab, symbol: "plus.square",
                                            effect: .perform { restorer.open(entry, newTab: true) }))
            secondary.append(PaletteCommand(id: "copy", title: HistoryAppStrings.copyURL, symbol: "doc.on.doc",
                                            effect: .perform { restorer.copy(url) }))
        case .location(_, let isCurrent):
            primaryTitle = HistoryAppStrings.goTo
            if isCurrent { accessory = HistoryAppStrings.current }
        case .closed:
            primaryTitle = HistoryAppStrings.reopen
        case .agent(let session):
            primaryTitle = HistoryAppStrings.resume
            if session.endedAt == nil { accessory = HistoryAppStrings.running }
            secondary.append(PaletteCommand(id: "copyID", title: HistoryAppStrings.copySessionID, symbol: "doc.on.doc",
                                            effect: .perform { restorer.copy(session.sessionID) }))
            if let command = session.resumeCommand {
                secondary.append(PaletteCommand(id: "copyResume", title: HistoryAppStrings.copyResumeCommand, symbol: "terminal",
                                                effect: .perform { restorer.copy(command) }))
            }
        case .command(let command):
            primaryTitle = HistoryAppStrings.runAgain
            if let text = command.command {
                secondary.append(PaletteCommand(id: "copyCommand", title: HistoryAppStrings.copyCommand, symbol: "doc.on.doc",
                                                effect: .perform { restorer.copy(text) }))
            }
        }
        if !entry.isAvailable { accessory = HistoryAppStrings.offline }
        secondary.append(PaletteCommand(id: "remove", title: HistoryAppStrings.remove, symbol: "trash", isDestructive: true,
                                        effect: .performKeepingOpen { services.history.remove(entry) }))
        let subtitle = [entry.detail, entry.machineName].compactMap { $0 }.joined(separator: " · ")
        return PaletteItem(
            id: entry.id, title: entry.title, subtitle: subtitle.isEmpty ? nil : subtitle, accessory: accessory,
            symbol: symbol(entry.kind), brand: agentBrand(entry), keywords: [entry.searchText], isEnabled: entry.isAvailable,
            primary: PaletteCommand(id: "open", title: primaryTitle, symbol: "return", effect: .perform { restorer.open(entry) }),
            secondary: secondary)
    }

    static func symbol(_ kind: HistoryEntry.Kind) -> String {
        switch kind {
        case .page: "globe"
        case .location: "location"
        case .closed: "arrow.uturn.backward"
        case .command: "terminal"
        case .agent: "sparkles"
        }
    }
}
