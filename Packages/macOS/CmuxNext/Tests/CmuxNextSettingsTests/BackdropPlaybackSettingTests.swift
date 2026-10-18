import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `appearance.backgroundVideo` (play, whenActive, still), `appearance.backgroundVideoOnBattery`
/// (play, pause) and `appearance.backgroundAvoidPanes` (backgrounds plan phase 5): defaults play,
/// play and on; bad values keep the default and say why; the rows offer every choice and agents
/// may set them like the other background rows.
struct BackdropPlaybackSettingTests {
    private static func parse(_ appearance: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: [], validMetrics: [])
    }

    @Test func defaultsPlayEverywhereAndAvoidPanes() {
        let snapshot = Self.parse([:])
        #expect(snapshot.backdropPlayback == BackdropPlaybackSettings(video: .play, onBattery: .play, avoidsPanes: true))
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func everyValueParses() {
        let snapshot = Self.parse(["backgroundVideo": "whenActive", "backgroundVideoOnBattery": "pause", "backgroundAvoidPanes": false])
        #expect(snapshot.backdropPlayback == BackdropPlaybackSettings(video: .whenActive, onBattery: .pause, avoidsPanes: false))
        #expect(Self.parse(["backgroundVideo": "still"]).backdropPlayback.video == .still)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(["backgroundVideo": "loud", "backgroundAvoidPanes": "yes"])
        #expect(snapshot.backdropPlayback == BackdropPlaybackSettings())
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.backgroundVideo" })
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.backgroundAvoidPanes" })
    }

    @Test func theRowsOfferEveryChoiceAndAgentsMaySetThem() throws {
        for (key, choices) in [("backgroundVideo", BackdropVideoMode.allCases.map(\.rawValue)),
                               ("backgroundVideoOnBattery", BackdropBatteryMode.allCases.map(\.rawValue))] {
            let row = try #require(SettingsSchema.descriptor(for: ["appearance", key]))
            guard case .choice(let offered) = row.kind else { return Issue.record("\(key) is not a choice row") }
            #expect(offered.map(\.value) == choices)
            #expect(row.defaultValue == .string("play"))
        }
        let avoid = try #require(SettingsSchema.descriptor(for: ["appearance", "backgroundAvoidPanes"]))
        #expect(avoid.defaultValue == .bool(true))
        for key in ["backgroundVideo", "backgroundVideoOnBattery", "backgroundAvoidPanes"] {
            #expect(SettingsSchema.agentSettableKeys.contains("appearance." + key))
        }
    }
}
