import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `appearance.backgroundVideo` (play, whenActive, still) and `appearance.backgroundVideoOnBattery`
/// (play, pause) (backgrounds plan phase 5): both default to play; bad values keep the default and
/// say why; the rows offer every choice and agents may set them like the other background rows.
/// Hand framing (`appearance.backgroundAvoidPanes`) went with #22562: the art aspect-fills.
struct BackdropPlaybackSettingTests {
    private static func parse(_ appearance: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: [], validMetrics: [])
    }

    @Test func defaultsPlayEverywhere() {
        let snapshot = Self.parse([:])
        #expect(snapshot.backdropPlayback == BackdropPlaybackSettings(video: .play, onBattery: .play))
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func everyValueParses() {
        let snapshot = Self.parse(["backgroundVideo": "whenActive", "backgroundVideoOnBattery": "pause"])
        #expect(snapshot.backdropPlayback == BackdropPlaybackSettings(video: .whenActive, onBattery: .pause))
        #expect(Self.parse(["backgroundVideo": "still"]).backdropPlayback.video == .still)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(["backgroundVideo": "loud", "backgroundVideoOnBattery": "sometimes"])
        #expect(snapshot.backdropPlayback == BackdropPlaybackSettings())
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.backgroundVideo" })
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.backgroundVideoOnBattery" })
    }

    @Test func theRowsOfferEveryChoiceAndAgentsMaySetThem() throws {
        for (key, choices) in [("backgroundVideo", BackdropVideoMode.allCases.map(\.rawValue)),
                               ("backgroundVideoOnBattery", BackdropBatteryMode.allCases.map(\.rawValue))] {
            let row = try #require(SettingsSchema.descriptor(for: ["appearance", key]))
            guard case .choice(let offered) = row.kind else {
            Issue.record("\(key) is not a choice row")
            return
        }
            #expect(offered.map(\.value) == choices)
            #expect(row.defaultValue == .string("play"))
        }
        #expect(SettingsSchema.descriptor(for: ["appearance", "backgroundAvoidPanes"]) == nil)
        for key in ["backgroundVideo", "backgroundVideoOnBattery"] {
            #expect(SettingsSchema.agentSettableKeys.contains("appearance." + key))
        }
    }

    /// `home.chiefPictureMotion`: hover by default, always and never parse, a bad value keeps
    /// hover and says why, and the Home row offers the three.
    @Test func chiefPictureMotionParsesAndHasItsRow() throws {
        let parse = { (value: JSONValue) in
            CmuxConfigSnapshot.parse(.object(["home": .object(["chiefPictureMotion": value])]), validDensities: [], validMetrics: [])
        }
        #expect(CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: []).chiefPictureMotion == .hover)
        #expect(parse("always").chiefPictureMotion == .always && parse("never").chiefPictureMotion == .never)
        let bad = parse("sometimes")
        #expect(bad.chiefPictureMotion == .hover && bad.diagnostics.contains { $0.path == "home.chiefPictureMotion" })
        let row = try #require(SettingsSchema.descriptor(for: ["home", "chiefPictureMotion"]))
        guard case .choice(let offered) = row.kind else {
            Issue.record("not a choice row")
            return
        }
        #expect(offered.map(\.value) == ChiefPictureMotion.allCases.map(\.rawValue) && row.defaultValue == .string("hover"))
        #expect(SettingsSchema.agentSettableKeys.contains("home.chiefPictureMotion"))
    }
}
