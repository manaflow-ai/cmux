import CmuxNextDaemon
import CmuxNextHomeModel
import Foundation

/// The Chief's Model popup below its "Default" item, built from the models acpmux offers for the
/// harness (plans/cmux-next/model-catalog.md is the rule set the agent pane's picker follows too):
///
/// - Recent picks on this harness first (not the current one).
/// - One section per family, in the harness's order, holding its newest release (every model
///   of the newest release date, and any model that names none); each model's context variant
///   ("Opus 5.5 · 1M context") right after it.
/// - Plan-and-execute combinations (Claude Code's `opusplan`), then models of no family.
/// - Older releases last, newest first.
///
/// One row per model: an alias the harness reports for a release (`opus` → Claude Opus 5.5)
/// takes that release's row and title, so a pick follows the harness's newest release, unless
/// the Chief is set on the release id itself. A chosen model the harness does not offer still
/// shows. A list with no families (a hosted Chief's) has no headers.
nonisolated struct HomeChiefModelMenu: Equatable {
    /// One model row: the value a pick writes and the title it shows.
    nonisolated struct Item: Equatable {
        var value: String
        var title: String
        /// The row's tooltip: the model's catalog description, then the id a pick writes.
        var detail: String?
    }

    nonisolated enum Entry: Equatable {
        case header(String)
        case model(Item)
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
    /// The rules are Rust's `chief_settings.modelMenu` (cmux-home-rules `chief_settings/model_menu.rs`).
    init(models: [ChiefEngineReport.Model], chosen: String?, recents: [String]) {
        let reply: Reply? = try? HomeRules.call(
            "chief_settings.modelMenu",
            MenuRequest(models: models, chosen: chosen, recents: recents, strings: HomeChiefRuleStrings()))
        self.init(entries: reply?.entries.map(\.entry) ?? [])
    }

    init(entries: [Entry]) {
        self.entries = entries
    }

    /// The release `id` runs: its own metadata row, or the release an alias (or a context variant
    /// of either) names. Shared with the Effort and Speed rows, which follow the shown model.
    /// Rust's `chief_settings.modelRelease`.
    static func release(of id: String, in models: [ChiefEngineReport.Model]) -> ChiefEngineReport.Model? {
        do {
            let release: ChiefEngineReport.Model? = try HomeRules.call("chief_settings.modelRelease", IdRequest(id: id, models: models, strings: nil))
            return release
        } catch {
            return nil
        }
    }

    /// The name a person reads for model `id`: the catalog's name for the release it runs (with
    /// its context variant), else the name acpmux gave it, else the id made readable
    /// (``Swift/String/chiefModelName``), never the raw id. Rust's `chief_settings.modelDisplayName`.
    static func name(of id: String, in models: [ChiefEngineReport.Model]) -> String {
        (try? HomeRules.call("chief_settings.modelDisplayName", IdRequest(id: id, models: models, strings: HomeChiefRuleStrings())))
            ?? id.chiefModelName
    }

    // MARK: Rules bridge

    private nonisolated struct MenuRequest: Encodable {
        var models: [ChiefEngineReport.Model]
        var chosen: String?
        var recents: [String]
        var strings: HomeChiefRuleStrings
    }

    private nonisolated struct IdRequest: Encodable {
        var id: String
        var models: [ChiefEngineReport.Model]
        var strings: HomeChiefRuleStrings?
    }

    /// `chief_settings.modelMenu`'s reply (and `engineTitles`' `menu`).
    nonisolated struct Reply: Decodable {
        var entries: [WireEntry]
    }

    /// One `{kind: "header", title}` or `{kind: "model", value, title, detail?}` entry.
    nonisolated struct WireEntry: Decodable {
        var kind: String
        var title: String
        var value: String?
        var detail: String?

        var entry: Entry {
            kind == "header" ? .header(title) : .model(Item(value: value ?? "", title: title, detail: detail))
        }
    }
}
