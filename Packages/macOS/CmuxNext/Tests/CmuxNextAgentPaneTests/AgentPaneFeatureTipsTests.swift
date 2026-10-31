import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Feature tips (`tips.state`, leo-workspace design/feature-tips.md). Leo, 2026-10-30: "no this
/// should be very very infrequent like app installation level frequent and if they havent used the
/// browser". A tip shows once per install, never when its feature was used, and at most one every
/// 14 days; an existing install never sees the Browser tip.
struct AgentPaneFeatureTipsTests {
    private static let browserTip = "agents-drive-visible-browser-tabs"

    private func defaults() throws -> UserDefaults {
        let suite = "AgentPaneFeatureTipsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func requestsDecodeAndAnythingElseIsRefused() {
        #expect(AgentPaneRequest(body: ["method": "tips.state"]) == .featureTips(.read))
        #expect(AgentPaneRequest(body: ["method": "tips.state", "params": [:] as [String: Any]]) == .featureTips(.read))
        #expect(AgentPaneRequest(body: ["method": "tips.state", "params": ["id": Self.browserTip, "state": "closed"]])
            == .featureTips(.keep(id: Self.browserTip, state: "closed")))
        #expect(AgentPaneRequest(body: ["method": "tips.state", "params": ["claim": Self.browserTip, "feature": "browser"]])
            == .featureTips(.claim(id: Self.browserTip, feature: "browser")))
        #expect(AgentPaneRequest(body: ["method": "tips.state", "params": ["claim": Self.browserTip]])
            == .featureTips(.claim(id: Self.browserTip, feature: nil)))
        let refused: [[String: Any]] = [
            ["id": "tip"], ["state": "closed"], ["id": "Tip", "state": "closed"], ["id": "tip", "state": "shown"],
            ["id": "tip", "state": "open"], ["id": "../tip", "state": "used"], ["id": 3, "state": "used"],
            ["id": String(repeating: "a", count: 81), "state": "used"], ["claim": "Tip"], ["claim": 1],
            ["claim": "tip", "feature": "Browser"], ["claim": "tip", "id": "tip"], ["id": "tip", "state": "used", "x": 1],
        ]
        for params in refused {
            #expect(AgentPaneRequest(body: ["method": "tips.state", "params": params]) == .unsupported("tips.state"))
        }
    }

    /// Shown once, then never again, after a relaunch (a new store on the same defaults) or an update.
    @Test func shownOncePerInstall() throws {
        let shared = try defaults()
        let firstLaunch = AgentPaneFeatureTipRecords(defaults: shared)
        firstLaunch.settleInstall(launchedBefore: false)
        #expect(firstLaunch.claim(Self.browserTip, feature: "browser"))
        #expect(!firstLaunch.claim(Self.browserTip, feature: "browser"))
        let later = Date().addingTimeInterval(365 * 86_400)
        let relaunched = AgentPaneFeatureTipRecords(defaults: shared, now: { later })
        relaunched.settleInstall(launchedBefore: true)
        #expect(!relaunched.claim(Self.browserTip, feature: "browser"))
        #expect(relaunched.records[Self.browserTip] == "shown")
    }

    @Test func neverWhenTheBrowserWasUsed() throws {
        let store = AgentPaneFeatureTipRecords(defaults: try defaults())
        store.settleInstall(launchedBefore: false)
        store.noteFeatureUsed(AgentPaneFeatureTipRecords.browserFeature)
        store.noteFeatureUsed(AgentPaneFeatureTipRecords.browserFeature)
        #expect(store.usedFeatures == ["browser"])
        #expect(!store.claim(Self.browserTip, feature: "browser"))
        #expect(store.records[Self.browserTip] == nil)
    }

    /// An install that ran before tips existed never sees the Browser tip, and the decision is made once:
    /// its later launches (which all have the record) do not change it, nor does a fresh one undo it.
    @Test func anExistingInstallSeesNoBrowserTip() throws {
        let shared = try defaults()
        let existing = AgentPaneFeatureTipRecords(defaults: shared)
        existing.settleInstall(launchedBefore: true)
        #expect(!existing.claim(Self.browserTip, feature: "browser"))
        let fresh = try defaults()
        let store = AgentPaneFeatureTipRecords(defaults: fresh)
        store.settleInstall(launchedBefore: false)
        store.settleInstall(launchedBefore: true)
        #expect(store.usedFeatures.isEmpty)
        #expect(store.claim(Self.browserTip, feature: "browser"))
    }

    @Test func atMostOneTipEveryFourteenDays() throws {
        let shared = try defaults()
        var today = Date()
        let store = AgentPaneFeatureTipRecords(defaults: shared, now: { today })
        #expect(store.claim("first-tip", feature: nil))
        today = today.addingTimeInterval(Double(AgentPaneFeatureTipRecords.minimumDaysBetweenTips) * 86_400 - 60)
        #expect(!store.claim("second-tip", feature: nil))
        today = today.addingTimeInterval(120)
        #expect(store.claim("second-tip", feature: nil))
    }

    @Test func closedAndUsedStaySo() throws {
        let store = AgentPaneFeatureTipRecords(defaults: try defaults())
        #expect(store.claim("a", feature: nil))
        store.keep("a", "closed")
        store.keep("a", "used")
        store.keep("b", "used")
        store.keep("b", "closed")
        #expect(store.records == ["a": "closed", "b": "used"])
    }

    @Test func recordsAreBounded() throws {
        let store = AgentPaneFeatureTipRecords(defaults: try defaults())
        for index in 0..<(AgentPaneFeatureTipRecords.maxRecords + 4) { store.keep("tip-\(index)", "used") }
        #expect(store.records.count == AgentPaneFeatureTipRecords.maxRecords)
        #expect(!store.claim("one-more", feature: nil))
    }

    @Test func thePageCanCallIt() {
        #expect(AgentPageOps.methods["tips.state"] == "tips.state")
    }

    @Test func theChatFollowsTheToggle() {
        let root = JSONValue.object(["updates": .object(["showFeatureTips": .bool(false)])])
        #expect(AgentPaneDisplaySetting(fileRoot: root).values["updates.showFeatureTips"] == .bool(false))
    }
}
