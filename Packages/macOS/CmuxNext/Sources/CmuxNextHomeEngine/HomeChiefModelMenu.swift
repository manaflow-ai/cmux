import CmuxNextDaemon
import Foundation

/// The Chief's Model popup below its "Default" item: acpmux's models for the harness, as offered.
nonisolated struct HomeChiefModelMenu: Equatable {
    /// One model row: the value a pick writes and the title it shows.
    nonisolated struct Item: Equatable {
        var value: String
        var title: String
        var detail: String?
    }

    nonisolated enum Entry: Equatable {
        case header(String)
        case model(Item)
    }

    let entries: [Entry]

    var items: [Item] {
        entries.compactMap { if case .model(let item) = $0 { item } else { nil } }
    }

    init(models: [ChiefEngineReport.Model], chosen: String?, recents: [String]) {
        var entries = models.filter { $0.id != "default" }.map { Entry.model(Item(value: $0.id, title: $0.name)) }
        if let chosen, chosen != "default", !models.contains(where: { $0.id == chosen }) {
            entries.append(.model(Item(value: chosen, title: chosen)))
        }
        self.entries = entries
    }

    static func release(of id: String, in models: [ChiefEngineReport.Model]) -> ChiefEngineReport.Model? {
        models.first { $0.id == id }
    }
}
