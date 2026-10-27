import CmuxNextDaemon
import CmuxNextHome
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
    init(models: [ChiefEngineReport.Model], chosen: String?, recents: [String]) {
        let rows = Self.rows(models, chosen: chosen)
        var entries: [Entry] = []
        let recentRows = recents.filter { $0 != chosen }.compactMap { value in rows.first { $0.item.value == value } }.prefix(3)
        if !recentRows.isEmpty {
            entries.append(.header(HomeEngineStrings.recentSection))
            entries += recentRows.map { Entry.model($0.item) }
        }
        let headed = rows.contains { $0.family != nil }
        let newest = Dictionary(rows.compactMap { row in row.family.flatMap { family in row.release.map { (family, $0) } } },
                                uniquingKeysWith: { max($0, $1) })
        let isOlder = { (row: Row) in
            guard let family = row.family, let release = row.release, let top = newest[family] else { return false }
            return release < top
        }
        var families: [String] = []
        for row in rows {
            if let family = row.family, !families.contains(family) { families.append(family) }
        }
        for family in families {
            let members = rows.filter { $0.family == family && !isOlder($0) }
            guard !members.isEmpty else { continue }
            entries.append(.header(family))
            entries += Self.withVariants(members).map { Entry.model($0.item) }
        }
        let plans = rows.filter { $0.kind == .plan }
        if !plans.isEmpty {
            if headed { entries.append(.header(HomeEngineStrings.planAndExecuteSection)) }
            entries += plans.map { Entry.model($0.item) }
        }
        let others = rows.filter { $0.family == nil && $0.kind == .model }
        if !others.isEmpty {
            if headed { entries.append(.header(HomeEngineStrings.otherModelsSection)) }
            entries += others.map { Entry.model($0.item) }
        }
        let older = rows.filter(isOlder).sorted { ($0.release ?? "") > ($1.release ?? "") }
        if !older.isEmpty {
            entries.append(.header(HomeEngineStrings.olderModelsSection))
            entries += Self.withVariants(older).map { Entry.model($0.item) }
        }
        self.entries = entries
    }

    /// The release `id` runs: its own metadata row, or the release an alias (or a context variant
    /// of either) names. Shared with the Effort and Speed rows, which follow the shown model.
    static func release(of id: String, in models: [ChiefEngineReport.Model]) -> ChiefEngineReport.Model? {
        let base = baseID(id)
        if let own = models.first(where: { $0.id == base && $0.family != nil }) { return own }
        let target = models.first { $0.id == base }?.resolvedModel ?? base
        return models.first { $0.family != nil && ($0.id == target || $0.aliases?.contains(base) == true) }
            ?? models.first { $0.id == base }
    }

    /// The name a person reads for model `id`: the catalog's name for the release it runs (with
    /// its context variant), else the name acpmux gave it, else the id made readable
    /// (``Swift/String/chiefModelName``), never the raw id.
    static func name(of id: String, in models: [ChiefEngineReport.Model]) -> String {
        if let release = release(of: id, in: models), release.family != nil {
            let name = displayName(release)
            return baseID(id) == id ? name : variantTitle(base: name, id: id)
        }
        if let own = models.first(where: { $0.id == id }) { return readable(own) }
        return id.chiefModelName
    }

    /// `model`'s own name, or its id made readable when acpmux named it by its id.
    static func readable(_ model: ChiefEngineReport.Model) -> String {
        let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == model.id ? model.id.chiefModelName : name
    }

    /// `id` without a context-window suffix (`opus[1m]` → `opus`).
    static func baseID(_ id: String) -> String {
        guard id.hasSuffix("]"), let open = id.lastIndex(of: "[") else { return id }
        return String(id[..<open])
    }

    // MARK: Rows

    private nonisolated enum Kind { case model, plan }

    private nonisolated struct Row {
        var item: Item
        var family: String?
        var release: String?
        var kind: Kind
        /// The release id this row stands for (a variant's base), which dedupes and orders it.
        var key: String
        var variant: Bool
        /// The catalog's description of the model, the first line of its tooltip.
        var description: String?
    }

    /// One row per offered model: acpmux's own `default` is the popup's Default item; an alias
    /// and its release become one row.
    private static func rows(_ models: [ChiefEngineReport.Model], chosen: String?) -> [Row] {
        var rows: [Row] = []
        var seen: [String: Int] = [:]
        for model in models where model.id != "default" {
            let release = Self.release(of: model.id, in: models)
            let isPlan = model.family == nil && release?.family == nil && model.id.lowercased().hasSuffix("plan")
            let base = baseID(model.id)
            let variant = base != model.id
            // A variant's key is its release's with the same suffix, so `opus[1m]` and
            // `claude-opus-5-5[1m]` are one row.
            let key = ((release?.family != nil ? release?.id : nil) ?? base) + model.id.dropFirst(base.count)
            var title = isPlan ? planTitle(model) : (release?.family != nil ? release.map(displayName) : nil) ?? readable(model)
            if variant { title = variantTitle(base: title, id: model.id) }
            let row = Row(item: Item(value: model.id, title: title, detail: isPlan ? planDetail(model, title: title) : nil), family: release?.family,
                          release: release?.releaseDate, kind: isPlan ? .plan : .model, key: key, variant: variant,
                          description: model.description ?? release?.description)
            if let index = seen[key] {
                // The alias wins the row unless the Chief is set on the other id.
                let keepsNew = model.id == chosen || (rows[index].item.value != chosen && isAlias(model, of: models))
                if keepsNew { rows[index].item.value = model.id }
                continue
            }
            seen[key] = rows.count
            rows.append(row)
        }
        if let chosen, chosen != "default", !rows.contains(where: { $0.item.value == chosen }) {
            // Named by its id made readable; the id itself is the row's tooltip.
            rows.append(Row(item: Item(value: chosen, title: chosen.chiefModelName), family: nil, release: nil,
                            kind: .model, key: chosen, variant: false, description: nil))
        }
        // The tooltip names the id the row writes once an alias and its release share the row.
        for index in rows.indices where rows[index].kind == .model {
            let item = rows[index].item
            let id = item.title == item.value ? nil : item.value
            let lines = [rows[index].description, id].compactMap { $0 }
            rows[index].item.detail = lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
        return rows
    }

    /// A model the harness names as an alias of a release (no catalog row of its own).
    private static func isAlias(_ model: ChiefEngineReport.Model, of models: [ChiefEngineReport.Model]) -> Bool {
        let base = baseID(model.id)
        return model.family == nil && (model.resolvedModel != nil || models.contains { $0.aliases?.contains(base) == true })
    }

    /// Each base row followed by its context variants (a variant with no base keeps its place).
    private static func withVariants(_ rows: [Row]) -> [Row] {
        var ordered: [Row] = []
        for row in rows where !row.variant {
            ordered.append(row)
            ordered += rows.filter { $0.variant && baseID($0.key) == row.key }
        }
        ordered += rows.filter { row in row.variant && !ordered.contains { $0.item.value == row.item.value } }
        return ordered
    }

    private static func displayName(_ model: ChiefEngineReport.Model) -> String {
        model.shortName ?? model.name
    }

    /// "Opus 5.5 · 1M context" for `[1m]`; another suffix shows as the harness wrote it.
    private static func variantTitle(base: String, id: String) -> String {
        let suffix = id[id.index(after: id.lastIndex(of: "[") ?? id.startIndex)...].dropLast().lowercased()
        let context = suffix.hasSuffix("m") || suffix.hasSuffix("k") ? suffix.uppercased() : String(suffix)
        return String(format: HomeEngineStrings.contextVariantFormat, base, context)
    }

    /// Claude Code's `opusplan`: Opus plans, Sonnet carries the plan out.
    /// Another plan reads by its own name, or by its id made readable (``readable(_:)``).
    private static func planTitle(_ model: ChiefEngineReport.Model) -> String {
        model.id == "opusplan" ? HomeEngineStrings.opusPlanTitle : readable(model)
    }

    /// A plan row's tooltip: the harness's own name for it, then the id the row writes.
    private static func planDetail(_ model: ChiefEngineReport.Model, title: String) -> String? {
        var lines: [String] = []
        for line in [model.name.trimmingCharacters(in: .whitespacesAndNewlines), model.id]
        where !line.isEmpty && line != title && !lines.contains(line) {
            lines.append(line)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
