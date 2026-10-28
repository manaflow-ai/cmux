import CmuxNextDaemon
import CmuxNextHome
import Foundation

/// The pickers' items and their "Default" titles for one snapshot: "Default"
/// alone says nothing, so for a field the owner has not chosen it names what the
/// brain runs ("Default (claude)", "Default (Opus 5.5)"), from the brain's report.
nonisolated struct HomeChiefEngineTitles {
    var harnesses: [(value: String, title: String)]
    /// Every model row's value and title, in the menu's order (``menu`` has its sections).
    var models: [(value: String, title: String)]
    var menu: HomeChiefModelMenu
    /// The efforts the shown model takes (the brain's list when the catalog does not say).
    var efforts: [(value: String, title: String)]
    var defaultHarness: String
    var defaultModel: String
    var defaultEffort: String
    /// Whether the Speed row shows: the turns' harness runs a fast tier, and the shown model
    /// does not say it has none (or the Chief is on Fast now, so it can be turned off).
    var offersFast: Bool

    /// - Parameter listed: this Mac's acpmux harness ids, offered after the official engines.
    init(_ snapshot: HomeChiefSnapshot, recents: [String] = [], listed: [String] = []) {
        harnesses = HomeChiefSettingsView.harnessItems(routeConfigured: snapshot.routeConfigured, listed: listed)
        // The models acpmux offers for the engine's harness (cx-miuo), grouped and deduped;
        // acpmux's own "default" is the picker's first item.
        menu = HomeChiefModelMenu(models: snapshot.models, chosen: snapshot.model, recents: recents)
        var seen = Set<String>()
        models = menu.items.filter { seen.insert($0.value).inserted }.map { ($0.value, $0.title) }
        let engine = snapshot.effective
        // The model the turns run: the chosen one, else what Default runs (the brain's
        // resolved model, else what acpmux's own "default" row resolves to).
        let defaultRuns = engine?.model ?? snapshot.models.first { $0.id == "default" }?.resolvedModel
        let running = (snapshot.model ?? defaultRuns).flatMap { HomeChiefModelMenu.release(of: $0, in: snapshot.models) }
        let takes = running?.efforts.map { levels in
            snapshot.efforts.isEmpty ? levels : levels.filter(snapshot.efforts.contains)
        }
        efforts = (takes.flatMap { $0.isEmpty ? nil : $0 } ?? snapshot.efforts).map { ($0, HomeEngineStrings.effortTitle($0)) }
        offersFast = snapshot.speeds.contains("fast") && (running?.fast != false || snapshot.speed == "fast")
        // The effective engine is engine.json over the brain's defaults, so it names what
        // Default runs only for a field with no choice; a chosen field's Default stays plain.
        defaultHarness = Self.titled((snapshot.harness == nil ? engine?.harness : nil).map { $0 == "default" ? $0 : ChiefBackend.title(for: $0) })
        let defaultModelRow = snapshot.model == nil ? defaultRuns.flatMap { HomeChiefModelMenu.release(of: $0, in: snapshot.models) } : nil
        // A model the catalog does not name reads by its id made readable, never the raw id.
        defaultModel = Self.titled(snapshot.model == nil
            ? defaultModelRow.map { $0.shortName ?? HomeChiefModelMenu.readable($0) } ?? defaultRuns.map { $0 == "default" ? $0 : HomeChiefModelMenu.name(of: $0, in: snapshot.models) }
            : nil)
        let defaultLevel = engine?.effort ?? running?.defaultEffort
        defaultEffort = Self.titled((snapshot.effort == nil ? defaultLevel : nil).map(HomeEngineStrings.effortTitle))
    }

    /// "Default (value)", or "Default" when the brain did not say (or says "default").
    static func titled(_ value: String?) -> String {
        guard let value, !value.isEmpty, value != "default" else { return HomeEngineStrings.defaultValue }
        return String(format: HomeEngineStrings.defaultNamedFormat, value)
    }
}
