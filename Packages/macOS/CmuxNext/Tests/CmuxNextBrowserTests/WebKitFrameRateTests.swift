import AppKit
import WebKit
import Testing
@testable import CmuxNextBrowser
import CmuxNextDesign

/// Browser tabs render at the display's full rate (120 Hz on ProMotion),
/// as the agent pane and React pages already do; Low Power Mode keeps
/// WebKit's rate nearest 60 fps, for open tabs as well as new ones.
@MainActor
@Suite(.serialized)
struct WebKitFrameRateTests {
    private static let feature = WebKitRenderRate.near60FPSFeature

    private static func near60(_ tab: WebKitTab) -> Bool? {
        tab.webView.configuration.preferences.isWebKitFeatureEnabled(feature)
    }

    @Test func browserTabsRenderAtFullRateUnlessLowPower() {
        let power = LowPowerMode(enabled: false)
        let engine = WebKitEngine(lowPowerMode: power)
        let tab = engine.makeWebKitTab(BrowserTabConfiguration(profile: .default))
        defer { tab.close() }
        // A WebKit without the feature has no rate to change.
        guard Self.near60(tab) != nil else { return }
        #expect(Self.near60(tab) == false)
        power.override = true
        let saving = engine.makeWebKitTab(BrowserTabConfiguration(profile: .default))
        defer { saving.close() }
        #expect(Self.near60(saving) == true, "a tab made during Low Power Mode starts near 60 fps")
    }

    /// Low Power Mode turning on reached only tabs made afterwards: open
    /// tabs kept 120 Hz until they were closed.
    @Test func openTabsDropToNear60WhenLowPowerModeTurnsOnAndReturnWhenItTurnsOff() {
        let power = LowPowerMode(enabled: false)
        let engine = WebKitEngine(lowPowerMode: power)
        let first = engine.makeWebKitTab(BrowserTabConfiguration(profile: .default))
        let second = engine.makeWebKitTab(BrowserTabConfiguration(profile: .default))
        defer { first.close(); second.close() }
        guard Self.near60(first) != nil else { return }
        power.override = true
        #expect(Self.near60(first) == true)
        #expect(Self.near60(second) == true)
        power.override = false
        #expect(Self.near60(first) == false)
        #expect(Self.near60(second) == false)
    }

    /// The system value: a power state notification re-reads it, with no
    /// polling in between.
    @Test func openTabsFollowThePowerStateNotification() async {
        let center = NotificationCenter()
        var system = false
        let power = LowPowerMode(center: center) { system }
        let engine = WebKitEngine(lowPowerMode: power)
        let tab = engine.makeWebKitTab(BrowserTabConfiguration(profile: .default))
        defer { tab.close() }
        guard Self.near60(tab) != nil else { return }
        system = true
        // Posted until heard: the observer's task starts listening on its first turn.
        for _ in 0..<1_000 where !power.isEnabled {
            center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
            await Task.yield()
        }
        #expect(power.isEnabled)
        #expect(Self.near60(tab) == true)
    }

    /// WebKit reads the rate only when the page's visibility changes, so a
    /// tab on screen is re-shown under a snapshot; on a 60 Hz display the
    /// rate is the same either way and the page is left alone.
    @Test func aTabOnScreenIsReShownUnderASnapshotOnlyWhenItsRateChanges() async {
        let power = LowPowerMode(enabled: false)
        let engine = WebKitEngine(lowPowerMode: power)
        let tab = engine.makeWebKitTab(BrowserTabConfiguration(profile: .default))
        defer { tab.close() }
        guard Self.near60(tab) != nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = tab.contentView
        var display = 120
        engine.displayFramesPerSecond = { _ in display }
        engine.rateReshowSnapshot = { NSImage(size: NSSize(width: 400, height: 300)) }
        var steps: [(hidden: Bool, covered: Bool)] = []
        engine.rateReshowClock = StepClock { [unowned tab] _ in
            steps.append((tab.webView.isHidden, tab.contentView.subviews.contains { $0 is NSImageView }))
        }
        power.override = true
        await tab.rateReshow?.value
        #expect(steps.first?.hidden == true)
        let coveredThroughout = !steps.isEmpty && steps.allSatisfy { $0.covered }
        #expect(coveredThroughout)
        #expect(!tab.webView.isHidden)
        #expect(!tab.contentView.subviews.contains { $0 is NSImageView })
        // 60 Hz: the preference changes, the page is not re-shown.
        steps = []
        display = 60
        power.override = false
        await tab.rateReshow?.value
        #expect(Self.near60(tab) == false)
        #expect(steps.isEmpty)
    }

    /// The rate a page renders at, from the power state and the display.
    @Test func theRenderRateFollowsPowerStateAndDisplay() {
        #expect(WebKitRenderRate.framesPerSecond(lowPowerMode: false, displayMaxFPS: 120) == 120)
        #expect(WebKitRenderRate.framesPerSecond(lowPowerMode: true, displayMaxFPS: 120) == 60)
        #expect(WebKitRenderRate.framesPerSecond(lowPowerMode: true, displayMaxFPS: 160) == 80)
        #expect(WebKitRenderRate.framesPerSecond(lowPowerMode: true, displayMaxFPS: 144) == 72)
        #expect(WebKitRenderRate.framesPerSecond(lowPowerMode: true, displayMaxFPS: 60) == 60)
        #expect(WebKitRenderRate.framesPerSecond(lowPowerMode: false, displayMaxFPS: 60) == 60)
    }
}
