@testable import CmuxNextSettings
import Testing

/// `launch.relaunchCoverSwap`: a Settings > Development choice (and a palette row in DEV and NIGHTLY), off
/// unless cmux-next.json picks another swap, settable by agents (looks only), read from the config snapshot when
/// a relaunch reveals its windows.
struct RelaunchCoverSwapSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let launch: [String: JSONValue] = value.map { ["relaunchCoverSwap": $0] } ?? [:]
        return CmuxConfigSnapshot.parse(.object(["launch": .object(launch)]), validDensities: [], validMetrics: [])
    }

    @Test func isADevelopmentChoiceWithOffByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: RelaunchCoverSwapSetting.configPath))
        #expect(RelaunchCoverSwapSetting.configPath == ["launch", "relaunchCoverSwap"])
        #expect(descriptor.section == .development)
        #expect(descriptor.isShownOnSettingsPage)
        #expect(descriptor.isPaletteListed(developerTools: true))
        #expect(descriptor.defaultValue == .string(RelaunchCoverSwap.off.rawValue))
        #expect(SettingsSchema.agentSettableKeys.contains(RelaunchCoverSwapSetting.key))
        guard case .choice(let choices) = descriptor.kind else { Issue.record("not a choice row"); return }
        #expect(choices.map(\.value) == ["off", "instant", "crossfade", "progressive"])
        #expect(choices.map(\.value) == RelaunchCoverSwap.allCases.map(\.rawValue))
    }

    @Test func eachSwapIsReadAndUnsetIsOff() {
        for swap in RelaunchCoverSwap.allCases {
            #expect(Self.parse(.string(swap.rawValue)).relaunchCoverSwap == swap)
        }
        #expect(Self.parse(nil).relaunchCoverSwap == .off)
        #expect(CmuxConfigSnapshot.empty.relaunchCoverSwap == .off)
        #expect(!Self.parse(.string("crossfade")).diagnostics.contains { $0.path == RelaunchCoverSwapSetting.key })
    }

    @Test func badValueUsesOffAndReportsIt() {
        let snapshot = Self.parse(.string("dissolve"))
        #expect(snapshot.relaunchCoverSwap == .off)
        #expect(snapshot.diagnostics.contains { $0.path == RelaunchCoverSwapSetting.key })
    }
}
