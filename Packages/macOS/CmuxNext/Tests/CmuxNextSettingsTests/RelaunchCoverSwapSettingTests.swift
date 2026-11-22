@testable import CmuxNextSettings
import Testing

/// `launch.relaunchCoverSwap`: a Settings > Development choice (and a palette row in DEV and NIGHTLY), crossfade
/// unless cmux-next.json picks another swap, settable by agents (looks only), read from the config snapshot when
/// a relaunch reveals its windows.
struct RelaunchCoverSwapSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let launch: [String: JSONValue] = value.map { ["relaunchCoverSwap": $0] } ?? [:]
        return CmuxConfigSnapshot.parse(.object(["launch": .object(launch)]), validDensities: [], validMetrics: [])
    }

    @Test func isADevelopmentChoiceWithCrossfadeByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: RelaunchCoverSwapSetting.configPath))
        #expect(RelaunchCoverSwapSetting.configPath == ["launch", "relaunchCoverSwap"])
        #expect(descriptor.section == .development)
        #expect(descriptor.isShownOnSettingsPage)
        #expect(descriptor.isPaletteListed(developerTools: true))
        #expect(descriptor.defaultValue == .string(RelaunchCoverSwap.crossfade.rawValue))
        #expect(SettingsSchema.agentSettableKeys.contains(RelaunchCoverSwapSetting.key))
        guard case .choice(let choices) = descriptor.kind else { Issue.record("not a choice row"); return }
        #expect(choices.map(\.value) == ["off", "instant", "crossfade", "progressive"])
        #expect(choices.map(\.value) == RelaunchCoverSwap.allCases.map(\.rawValue))
    }

    @Test func eachSwapIsReadAndUnsetIsCrossfade() {
        for swap in RelaunchCoverSwap.allCases {
            #expect(Self.parse(.string(swap.rawValue)).relaunchCoverSwap == swap)
        }
        #expect(Self.parse(nil).relaunchCoverSwap == .crossfade)
        #expect(CmuxConfigSnapshot.empty.relaunchCoverSwap == .crossfade)
        #expect(!Self.parse(.string("off")).diagnostics.contains { $0.path == RelaunchCoverSwapSetting.key })
    }

    @Test func badValueUsesCrossfadeAndReportsIt() {
        let snapshot = Self.parse(.string("dissolve"))
        #expect(snapshot.relaunchCoverSwap == .crossfade)
        #expect(snapshot.diagnostics.contains { $0.path == RelaunchCoverSwapSetting.key })
    }
}
