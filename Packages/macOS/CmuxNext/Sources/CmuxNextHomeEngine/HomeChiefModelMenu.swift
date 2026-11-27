import CmuxNextDaemon
import CmuxNextHomeModel
import Foundation

/// The Chief's Model popup below its "Default" item, built from the models acpmux offers for the
/// harness (plans/cmux-next/model-catalog.md). The rules (recents, one section per family's newest
/// release with its context variants, plan-and-execute, other models, older releases; an alias
/// takes its release's row) are cmux-home-rules' `chief_settings.modelMenu`, `modelRelease` and
/// `modelDisplayName`; this type passes the localized words and decodes the reply.
nonisolated struct HomeChiefModelMenu: Equatable {
    /// One model row: the value a pick writes and the title it shows.
    nonisolated struct Item: Equatable, Decodable {
        var value: String
        var title: String
        /// The row's tooltip: the model's catalog description, then the id a pick writes.
        var detail: String?
    }

    nonisolated enum Entry: Equatable, Decodable {
        case header(String)
        case model(Item)

        private enum CodingKeys: String, CodingKey { case kind, title }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if try c.decode(String.self, forKey: .kind) == "header" {
                self = .header(try c.decode(String.self, forKey: .title))
            } else {
                self = .model(try Item(from: decoder))
            }
        }
    }

    let entries: [Entry]

    /// Every model row, in order (a recent model also shows in its own section).
    var items: [Item] {
        entries.compactMap { if case .model(let item) = $0 { item } else { nil } }
    }

    /// - Parameters:
    ///   - models: acpmux's models for the harness, in its order.
    ///   - chosen: the engine's chosen model (nil: Default).
    ///   - recents: this harness's recent picks, newest first.
    init(models: [ChiefEngineReport.Model], chosen: String?, recents: [String]) {
        let reply: Reply? = HomeRust.call("chief_settings.modelMenu",
                                          MenuRequest(models: models, chosen: chosen, recents: recents, strings: .current))
        entries = reply?.entries ?? []
    }

    /// The release `id` runs: its own metadata row, or the release an alias (or a context variant
    /// of either) names. Shared with the Effort and Speed rows, which follow the shown model.
    static func release(of id: String, in models: [ChiefEngineReport.Model]) -> ChiefEngineReport.Model? {
        let reply: ChiefEngineReport.Model?? = HomeRust.call("chief_settings.modelRelease", IDRequest(id: id, models: models, strings: nil))
        return reply ?? nil
    }

    /// The name a person reads for model `id`: the catalog's name for the release it runs (with
    /// its context variant), else the name acpmux gave it, else the id made readable, never the raw id.
    static func name(of id: String, in models: [ChiefEngineReport.Model]) -> String {
        HomeRust.call("chief_settings.modelDisplayName", IDRequest(id: id, models: models, strings: .current)) ?? id.chiefModelName
    }

    /// `model`'s own name, or its id made readable when acpmux named it by its id.
    static func readable(_ model: ChiefEngineReport.Model) -> String {
        let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == model.id ? model.id.chiefModelName : name
    }

    // MARK: Requests

    private nonisolated struct Reply: Decodable { let entries: [Entry] }

    private nonisolated struct MenuRequest: Encodable {
        let models: [ChiefEngineReport.Model], chosen: String?, recents: [String], strings: Words
    }

    private nonisolated struct IDRequest: Encodable {
        let id: String, models: [ChiefEngineReport.Model], strings: Words?
    }

    /// The localized words the rules put in titles (`chief_settings::Strings`).
    private nonisolated struct Words: Encodable {
        let recentSection, planAndExecuteSection, otherModelsSection, olderModelsSection: String
        let opusPlanTitle, contextVariantFormat: String

        static var current: Words {
            Words(recentSection: HomeEngineStrings.recentSection, planAndExecuteSection: HomeEngineStrings.planAndExecuteSection,
                  otherModelsSection: HomeEngineStrings.otherModelsSection, olderModelsSection: HomeEngineStrings.olderModelsSection,
                  opusPlanTitle: HomeEngineStrings.opusPlanTitle, contextVariantFormat: HomeEngineStrings.contextVariantFormat)
        }
    }
}
