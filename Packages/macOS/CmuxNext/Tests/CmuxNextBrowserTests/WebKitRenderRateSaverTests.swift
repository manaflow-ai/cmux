import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextWakeups
import Testing
import WebKit

/// `WebKitEngine` follows the app's Energy Saver policy (`MainWorkScheduler.energy`):
/// open tabs and new tabs render near 60 fps under the saver (or Low Power Mode while the `energySaver`
/// feature is off, `EnergyPolicy.pageSaver`), at the display's full rate without it. Off screen, no tab
/// re-shows under a snapshot; the rate is set on its preferences.
@MainActor @Suite(.serialized) struct WebKitRenderRateSaverTests {
    static func near60(_ tab: WebKitTab) throws -> Bool {
        try #require(tab.webView.configuration.preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature),
                     "this WebKit has no \(WebKitRenderRate.near60FPSFeature) feature")
    }

    static let saver = EnergyPolicy(saverReason: .setting)

    @MainActor final class Snapshots {
        var count = 0
    }

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

    /// Only the saver moves the rate. The engine follows the source (the saver turns the rate down), and
    /// then a policy change that keeps the saver as it was (on battery, screens asleep) leaves the rate.
    @Test func onlyTheSaverMovesTheRate() throws {
        let energy = EnergyPolicySource()
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory(), energy: energy)
        let tab = engine.makeWebKitTab()
        defer { tab.close() }
        energy.update(Self.saver)
        #expect(try Self.near60(tab), "the engine does not follow its policy source")
        energy.update(EnergyPolicy(saverReason: .setting, onBattery: true))
        #expect(try Self.near60(tab), "a change that kept the saver restored the full rate")
        energy.update(.normal)
        #expect(try !Self.near60(tab))
        energy.update(EnergyPolicy(screensAsleep: true, onBattery: true))
        #expect(!engine.energySaver)
        #expect(try !Self.near60(tab), "a change without the saver turned the rate down")
    }

    /// Low Power Mode while the `energySaver` feature is off turns the rate down, as before the saver.
    @Test func theLowPowerFallbackTurnsTheRateDown() throws {
        let energy = EnergyPolicySource()
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory(), energy: energy)
        let tab = engine.makeWebKitTab()
        defer { tab.close() }
        energy.update(EnergyPolicy(lowPowerFallback: true))
        #expect(engine.energySaver)
        #expect(try Self.near60(tab), "the open tab kept the full rate in Low Power Mode with the feature off")
        energy.update(.normal)
        #expect(try !Self.near60(tab))
    }

    @Test func aNewTabStartsAtTheRateForTheCurrentPolicy() throws {
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory(), energy: EnergyPolicySource(Self.saver))
        let tab = engine.makeWebKitTab()
        defer { tab.close() }
        #expect(engine.energySaver)
        #expect(try Self.near60(tab))
    }

    /// Quick saver changes (on, off, on in one turn) re-show a visible tab on a 120 Hz display once:
    /// each re-show replaces the one before it that has not started.
    @Test func quickSaverChangesReshowAVisibleTabOnce() async throws {
        _ = NSApplication.shared
        let energy = EnergyPolicySource()
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory(), energy: energy)
        let snapshots = Snapshots()
        engine.displayFramesPerSecond = { _ in 120 }
        engine.rateReshowSnapshot = {
            snapshots.count += 1
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        let tab = engine.makeWebKitTab()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer {
            tab.close()
            window.close()
        }
        tab.webView.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        window.contentView?.addSubview(tab.webView)
        energy.update(Self.saver)
        energy.update(.normal)
        energy.update(Self.saver)
        await tab.rateReshow?.value
        #expect(snapshots.count == 1, "quick saver changes re-showed the visible tab \(snapshots.count) times")
        #expect(try Self.near60(tab))
    }
}
