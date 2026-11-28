import CmuxNextSettings
import Testing

/// `mobile.siteDataHandoff`, `mobile.terminalSizing` and `mobile.terminalSizingOrder` (Settings > Mobile):
/// this Mac's terminal sizing policy, which the cmux-tui daemon applies and the
/// iPhone app edits (cmux-next-ios/PROTOCOL.md "Terminal sizing policy").
struct MobileTerminalSizingSettingTests {
    private static func parse(_ mobile: [String: JSONValue]?) -> CmuxConfigSnapshot {
        let root: JSONValue = mobile.map { .object(["mobile": .object($0)]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func fitsTheSmallestViewerUntilChanged() {
        let mobile = Self.parse(nil).mobile
        #expect(mobile.terminalSizing == .smallest)
        #expect(mobile.terminalSizingOrder.isEmpty)
    }

    @Test func siteDataHandoffIsOffUntilThePersonEnablesIt() {
        #expect(!Self.parse(nil).mobile.siteDataHandoff)
        #expect(Self.parse(["siteDataHandoff": .bool(true)]).mobile.siteDataHandoff)
        #expect(!Self.parse(["siteDataHandoff": .bool(false)]).mobile.siteDataHandoff)
    }

    @Test func malformedSiteDataHandoffKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(["siteDataHandoff": .string("yes")])
        #expect(!snapshot.mobile.siteDataHandoff)
        #expect(snapshot.diagnostics.contains { $0.path == "mobile.siteDataHandoff" })
    }

    @Test func eachKeyLoads() {
        let mobile = Self.parse([
            "terminalSizing": .string("priority"),
            "terminalSizingOrder": .array([.string("device:ABC-1"), .string("mac"), .string("mac"), .string("")]),
        ]).mobile
        #expect(mobile.terminalSizing == .priority)
        // In order, each token once, empty tokens dropped.
        #expect(mobile.terminalSizingOrder == ["device:ABC-1", "mac"])
        for mode in ["smallest", "mac", "latest", "priority"] {
            #expect(Self.parse(["terminalSizing": .string(mode)]).mobile.terminalSizing.rawValue == mode)
        }
    }

    @Test func aBadModeKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(["terminalSizing": .string("largest")])
        #expect(snapshot.mobile.terminalSizing == .smallest)
        #expect(snapshot.diagnostics.contains { $0.path == "mobile.terminalSizing" })
    }

    @Test func theModeIsAChoiceOnTheMobilePageAndTheOrderIsHidden() throws {
        let mode = try #require(SettingsSchema.descriptor(for: MobileSettings.terminalSizingPath))
        #expect(mode.defaultValue == .string("smallest"))
        guard case .choice(let choices) = mode.kind else {
            Issue.record("mobile.terminalSizing is not a choice")
            return
        }
        #expect(choices.map(\.value) == ["smallest", "mac", "latest", "priority"])
        let order = try #require(SettingsSchema.descriptor(for: MobileSettings.terminalSizingOrderPath))
        #expect(order.defaultValue == .array([]))
        let handoff = try #require(SettingsSchema.descriptor(for: MobileSettings.siteDataHandoffPath))
        #expect(handoff.defaultValue == .bool(false))
        #expect(handoff.kind == .toggle)
        let mobile = try #require(SettingsPageLayout().categories().first { $0.spec.id == "mobile" })
        #expect(mobile.groups.flatMap(\.rows).filter { $0.hasPrefix("mobile.") } == ["mobile.allowIPhoneConnections", "mobile.siteDataHandoff", "mobile.terminalSizing"])
        // Only the person (here or on the phone, through the daemon) changes it.
        #expect(SettingsSchema.agentRefusedKeys["mobile.siteDataHandoff"] == .userOnly)
        #expect(SettingsSchema.agentRefusedKeys["mobile.terminalSizing"] == .userOnly)
        #expect(SettingsSchema.agentRefusedKeys["mobile.terminalSizingOrder"] == .userOnly)
    }
}
