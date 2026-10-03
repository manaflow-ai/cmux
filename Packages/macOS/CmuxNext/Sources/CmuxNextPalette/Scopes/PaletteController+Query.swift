public import CmuxNextActions
import Foundation

/// One ranked row of `palette.query`: what an agent needs to act on it.
nonisolated public struct PaletteQueryRow: Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let accessory: String?
    public let section: String?
    public let symbol: String?
    public let score: Int
    /// The registry action the row runs, if any (`cmux action run <id>`).
    public let actionID: String?
    public let enters: PaletteScopeID?
    public let drills: PaletteScopeID?
    public let isEnabled: Bool
}

/// Headless palette: the scope graph and ranked rows of any scope, with no
/// UI and no focus change (`palette.scopes`, `palette.query`).
extension PaletteController {
    /// Every scope the palette knows now, root excluded, in scope-list order.
    public func scopeDescriptors() -> [PaletteScopeDescriptor] {
        configureScopes()
        let graph = model.navigation.graph
        return graph.order.compactMap { graph.scopes[$0] }
    }

    /// The rows `scope` shows for `text`, ranked like the palette with the
    /// user's usage, best first. Nil when the scope does not exist or has no
    /// page here (a drill-only scope such as `actions`).
    public func query(scope: PaletteScopeID, text: String, limit: Int) async -> [PaletteQueryRow]? {
        configureScopes()
        guard scope == .root || model.navigation.graph.contains(scope), let page = page(forScope: scope, context: nil) else { return nil }
        let state = PageState(kind: .list(page))
        for provider in page.providers {
            if let items = provider.immediateItems {
                state.providerItems[provider.id] = items
            } else {
                state.providerItems[provider.id] = await provider.items()
            }
        }
        state.rebuild()
        let ranked: [PaletteRankedSection]
        if FuzzyQuery(text).isEmpty {
            ranked = PaletteRanker.rankEmpty(entries: state.entries, sectionOrders: state.sectionOrders, frecency: model.frecency,
                                             now: model.now(), showsRecent: page.showsRecent)
        } else {
            // A searcher of its own: the open palette's index stays as it is.
            let searcher = PaletteSearcher()
            await searcher.install(entries: state.entries, version: state.version)
            ranked = await searcher.search(query: text, generation: 0, sectionOrders: state.sectionOrders, frecency: model.frecency,
                                           now: model.now(), showsRecent: page.showsRecent,
                                           keepsSectionOrder: page.keepsSectionOrder).sections
        }
        return state.resolve(ranked).flatMap { section in
            section.rows.map { row in
                let item = row.item
                return PaletteQueryRow(id: item.id, title: item.title, subtitle: item.subtitle, accessory: item.accessory,
                                       section: section.title.isEmpty ? nil : section.title, symbol: item.symbol, score: row.score,
                                       actionID: item.actionID?.rawValue, enters: item.enters, drills: item.drills, isEnabled: item.isEnabled)
            }
        }.prefix(max(0, limit)).map { $0 }
    }
}
