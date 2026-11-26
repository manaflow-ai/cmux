import CmuxNextDaemon
import CmuxNextHomeModel
import Foundation

/// The pickers' items and their "Default" titles for one snapshot: "Default"
/// alone says nothing, so for a field the owner has not chosen it names what the
/// brain runs ("Default (claude)", "Default (Opus 5.5)"), from the brain's report.
/// The rules are Rust's `chief_settings.engineTitles` (cmux-home-rules `chief_settings/engine.rs`).
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
        let reply: Reply? = try? HomeRules.call(
            "chief_settings.engineTitles",
            Request(snapshot: HomeChiefSnapshotWire(snapshot), recents: recents, listed: listed, strings: HomeChiefRuleStrings()))
        harnesses = reply?.harnesses.map { ($0.value, $0.title) } ?? []
        models = reply?.models.map { ($0.value, $0.title) } ?? []
        menu = HomeChiefModelMenu(entries: reply?.menu.entries.map(\.entry) ?? [])
        efforts = reply?.efforts.map { ($0.value, $0.title) } ?? []
        defaultHarness = reply?.defaultHarness ?? HomeEngineStrings.defaultValue
        defaultModel = reply?.defaultModel ?? HomeEngineStrings.defaultValue
        defaultEffort = reply?.defaultEffort ?? HomeEngineStrings.defaultValue
        offersFast = reply?.offersFast ?? false
    }

    /// "Default (value)", or "Default" when the brain did not say (or says "default").
    /// Rust's `chief_settings.defaultTitled`.
    static func titled(_ value: String?) -> String {
        (try? HomeRules.call("chief_settings.defaultTitled", TitledRequest(value: value, strings: HomeChiefRuleStrings())))
            ?? HomeEngineStrings.defaultValue
    }

    private nonisolated struct Request: Encodable {
        var snapshot: HomeChiefSnapshotWire
        var recents: [String]
        var listed: [String]
        var strings: HomeChiefRuleStrings
    }

    private nonisolated struct TitledRequest: Encodable {
        var value: String?
        var strings: HomeChiefRuleStrings
    }

    private nonisolated struct Pick: Decodable {
        var value: String
        var title: String
    }

    private nonisolated struct Reply: Decodable {
        var harnesses: [Pick]
        var models: [Pick]
        var menu: HomeChiefModelMenu.Reply
        var efforts: [Pick]
        var defaultHarness: String
        var defaultModel: String
        var defaultEffort: String
        var offersFast: Bool
    }
}

/// ``HomeChiefSnapshot`` as the rules read and return it (cmux-home-rules `chief_settings::Snapshot`):
/// every field but the trace's turns, which stay in Swift.
nonisolated struct HomeChiefSnapshotWire: Codable {
    var harness: String?
    var model: String?
    var effort: String?
    var speed: String?
    var avatar: String?
    var routeConfigured: Bool
    var models: [ChiefEngineReport.Model]
    var efforts: [String]
    var speeds: [String]
    var effective: ChiefEngineReport.Engine?
    var classifierHarness: String?
    var classifierModel: String?
    var classifierPrompt: String?
    var reactionsCanWake: String?
    var brainOff: Bool
    var computer: String?

    init(_ snapshot: HomeChiefSnapshot) {
        harness = snapshot.harness
        model = snapshot.model
        effort = snapshot.effort
        speed = snapshot.speed
        avatar = snapshot.avatar
        routeConfigured = snapshot.routeConfigured
        models = snapshot.models
        efforts = snapshot.efforts
        speeds = snapshot.speeds
        effective = snapshot.effective
        classifierHarness = snapshot.classifierHarness
        classifierModel = snapshot.classifierModel
        classifierPrompt = snapshot.classifierPrompt
        reactionsCanWake = snapshot.reactionsCanWake
        brainOff = snapshot.brainOff
        computer = snapshot.computer
    }

    /// The snapshot these fields make, with `turns` (the rules never see the trace).
    func snapshot(turns: [HomeEngineTurn]) -> HomeChiefSnapshot {
        var snapshot = HomeChiefSnapshot(harness: harness, model: model, effort: effort, speed: speed, avatar: avatar, turns: turns)
        snapshot.routeConfigured = routeConfigured
        snapshot.models = models
        snapshot.efforts = efforts
        snapshot.speeds = speeds
        snapshot.effective = effective
        snapshot.classifierHarness = classifierHarness
        snapshot.classifierModel = classifierModel
        snapshot.classifierPrompt = classifierPrompt
        snapshot.reactionsCanWake = reactionsCanWake
        snapshot.brainOff = brainOff
        snapshot.computer = computer
        return snapshot
    }
}
