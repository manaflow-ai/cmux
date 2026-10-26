@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextWakeups
import Testing
import WebKit

/// `WebKitEngine` follows the app's Energy Saver policy (`MainWorkScheduler.energy`, p14-energy-031):
/// open tabs and new tabs render near 60 fps under the saver, at the display's full rate without it.
/// Off screen, so no tab re-shows under a snapshot; the rate is set on its preferences.
@MainActor @Suite(.serialized) struct WebKitRenderRateSaverTests {
    static func near60(_ tab: WebKitTab) throws -> Bool {
        try #require(tab.webView.configuration.preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature),
                     "this WebKit has no \(WebKitRenderRate.near60FPSFeature) feature")
    }

    static let saver = EnergyPolicy(saverReason: .setting)

    @Test func anOpenTabFollowsTheSaver() throws {
        let energy = EnergyPolicySource()
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory(), energy: energy)
        let tab = engine.makeWebKitTab()
        defer { tab.close() }
        #expect(try !Self.near60(tab), "a tab opened without the saver renders near 60 fps")
        energy.update(Self.saver)
        #expect(engine.energySaver)
        #expect(try Self.near60(tab), "the open tab kept the full rate under Energy Saver")
        energy.update(.normal)
        #expect(try !Self.near60(tab), "the open tab stayed near 60 fps after Energy Saver ended")
    }

    /// Only the saver moves the rate: a policy change that leaves it off (on battery, screens asleep) does not.
    @Test func aPolicyChangeWithoutTheSaverKeepsTheFullRate() throws {
        let energy = EnergyPolicySource()
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory(), energy: energy)
        let tab = engine.makeWebKitTab()
        defer { tab.close() }
        energy.update(EnergyPolicy(screensAsleep: true, onBattery: true))
        #expect(!engine.energySaver)
        #expect(try !Self.near60(tab))
    }

    @Test func aNewTabStartsAtTheRateForTheCurrentPolicy() throws {
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory(), energy: EnergyPolicySource(Self.saver))
        let tab = engine.makeWebKitTab()
        defer { tab.close() }
        #expect(engine.energySaver)
        #expect(try Self.near60(tab))
    }
}
