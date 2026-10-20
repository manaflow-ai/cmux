import Foundation

/// The pickers' items and their "Default" titles for one snapshot: "Default"
/// alone says nothing, so for a field the owner has not chosen it names what the
/// brain runs ("Default (claude)", "Default (Opus 5.5)"), from the brain's report.
nonisolated struct HomeChiefEngineTitles {
    var harnesses: [(value: String, title: String)]
    var models: [(value: String, title: String)]
    var efforts: [(value: String, title: String)]
    var defaultHarness: String
    var defaultModel: String
    var defaultEffort: String

    init(_ snapshot: HomeChiefSnapshot) {
        harnesses = HomeChiefSettingsView.harnesses(routeConfigured: snapshot.routeConfigured).map { ($0, $0) }
        // The models acpmux offers for the engine's harness and the efforts the brain takes
        // (cx-miuo); acpmux's own "default" is the picker's first item.
        models = snapshot.models.filter { $0.id != "default" }.map { ($0.id, $0.name) }
        efforts = snapshot.efforts.map { ($0, $0) }
        // The effective engine is engine.json over the brain's defaults, so it names what
        // Default runs only for a field with no choice; a chosen field's Default stays plain.
        let engine = snapshot.effective
        defaultHarness = Self.titled(snapshot.harness == nil ? engine?.harness : nil)
        // A model id the offer names shows by its name.
        let model = snapshot.model == nil ? engine?.model : nil
        defaultModel = Self.titled(model.map { id in snapshot.models.first { $0.id == id }?.name ?? id })
        defaultEffort = Self.titled(snapshot.effort == nil ? engine?.effort : nil)
    }

    /// "Default (value)", or "Default" when the brain did not say (or says "default").
    static func titled(_ value: String?) -> String {
        guard let value, !value.isEmpty, value != "default" else { return HomeEngineStrings.defaultValue }
        return String(format: HomeEngineStrings.defaultNamedFormat, value)
    }
}
