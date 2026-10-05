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
    /// The row's typed commands, primary first, titles filled from the
    /// catalog (`palette.run`). Empty for a row only the UI can run.
    public var actions: [PaletteActionRef] = []
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
        guard let (page, state) = await loadedPage(scope) else { return nil }
        let ranked: [PaletteRankedSection]
        if FuzzyQuery(text).isEmpty {
            ranked = model.ranker.rankEmpty(entries: state.entries, sectionOrders: state.sectionOrders, frecency: model.frecency,
                                             now: model.now(), showsRecent: page.showsRecent)
        } else {
            // Reuse the model's bridge and index cache. The versioned install
            // keeps this headless query from rebuilding the JavaScript context.
            let searcher = model.searcher
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
                                       actionID: item.actionID?.rawValue, enters: item.enters, drills: item.drills, isEnabled: item.isEnabled,
                                       actions: titled(item.actionRefs))
            }
        }.prefix(max(0, limit)).map { $0 }
    }

    /// The ref `palette.run` runs for row `item` of `scope`: the row is
    /// looked up among all the scope's rows (not only the top ranked ones),
    /// then `PaletteRunSelection().pick` chooses its ref.
    public func runnableRef(scope: PaletteScopeID, item: String, action: String?) async throws(PaletteRunSelection.Failure) -> PaletteActionRef {
        guard let (page, state) = await loadedPage(scope) else { throw .unknownScope }
        let rows = page.providers.compactMap { state.providerItems[$0.id] }.joined()
        guard let row = rows.first(where: { $0.id == item }) else { throw .refused(.unknownItem(scope: scope.rawValue, item: item)) }
        do throws(PaletteRunRefusal) {
            return try PaletteRunSelection().pick(titled(row.actionRefs), title: row.title, item: item, action: action)
        } catch {
            throw .refused(error)
        }
    }

    /// `scope`'s page with every provider's items loaded, built headless.
    private func loadedPage(_ scope: PaletteScopeID) async -> (PalettePageSpec, PageState)? {
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
        return (page, state)
    }

    private func titled(_ refs: [PaletteActionRef]) -> [PaletteActionRef] {
        refs.map { ref in
            var ref = ref
            // The catalog is the truth for the title and for confirmation.
            if let descriptor = registry.descriptor(for: ref.action) {
                if ref.title == nil { ref.title = descriptor.title }
                ref.isDestructive = descriptor.isDestructive
            }
            return ref
        }
    }
}
