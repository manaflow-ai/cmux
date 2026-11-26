import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `appearance.statusIndicator.iconSet`: the status icon set as a user setting (it was only the
/// Debug tunable `status.iconSet`). Unset, every indicator keeps today's set (`codex`); the
/// setting picks another; a Debug override still wins over it.
@MainActor struct StatusIconSetSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let indicator: JSONValue = value.map { .object(["iconSet": $0]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(.object(["appearance": .object(["statusIndicator": indicator])]),
                                        validDensities: [], validMetrics: [])
    }

    /// A store with no override, or with `override` for `status.iconSet`.
    private static func store(override: StatusIconSet? = nil) -> TunableStore {
        let store = TunableStore()
        store.register([StatusIconSet.tunable.descriptor])
        store.activate(file: nil)
        if let override { store.set(StatusIconSet.tunable.key, .choice(override.rawValue)) }
        return store
    }

    @Test func unsetKeepsTodaysSet() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.statusIndicator.iconSet == nil)
        #expect(snapshot.statusIndicator == StatusIndicatorSettings())
        #expect(snapshot.diagnostics.isEmpty)
        #expect(StatusIconSet.resolved(setting: snapshot.statusIndicator.iconSet, in: Self.store()) == .codex)
        #expect(StatusIconSet.resolved(setting: nil, in: Self.store()) == StatusIconSet.tunable.defaultValue)
    }

    @Test(arguments: [StatusIconSet.current, .still, .symbols, .symbolsOutline, .pips, .rings, .badges, .signs, .codex])
    func theSettingPicksTheSet(_ set: StatusIconSet) {
        let snapshot = Self.parse(.string(set.rawValue))
        #expect(snapshot.statusIndicator.iconSet == set.rawValue)
        #expect(snapshot.diagnostics.isEmpty)
        #expect(StatusIconSet.resolved(setting: snapshot.statusIndicator.iconSet, in: Self.store()) == set)
    }

    @Test func aDebugOverrideWinsOverTheSetting() {
        let snapshot = Self.parse(.string("signs"))
        #expect(StatusIconSet.resolved(setting: snapshot.statusIndicator.iconSet, in: Self.store(override: .rings)) == .rings)
        #expect(StatusIconSet.resolved(setting: nil, in: Self.store(override: .current)) == .current)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("sparkles"))
        #expect(snapshot.statusIndicator.iconSet == nil)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.statusIndicator.iconSet" })
    }

    @Test(arguments: StatusIconSet.allCases.filter(\.isDebugOnly))
    func aDebugOnlySetIsNotTheSettings(_ set: StatusIconSet) {
        let snapshot = Self.parse(.string(set.rawValue))
        #expect(snapshot.statusIndicator.iconSet == nil)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.statusIndicator.iconSet" })
    }

    @Test func theSettingsRowOffersRealSetsAndDefaultsToTheTunablesDefault() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["appearance", "statusIndicator", "iconSet"]))
        #expect(row.defaultValue == .string(StatusIconSet.tunable.defaultValue.rawValue))
        guard case .choice(let choices) = row.kind else {
            Issue.record("not a choice row: \(row.kind)")
            return
        }
        let sets = choices.map { StatusIconSet(rawValue: $0.value) }
        #expect(sets.allSatisfy { $0 != nil && $0?.isDebugOnly == false })
        #expect(choices.first?.value == StatusIconSet.codex.rawValue)
        #expect(SettingsSchema.agentSettableKeys.contains("appearance.statusIndicator.iconSet"))
    }
}
