import AppKit
@testable import CmuxNextDesign
import Testing

/// A spinner that stopped comes back on its own (Leo 2026-10-20, ~17 sidebar rows with a still
/// arc: "why do these things not spin? Why have they not spun for a while?"). A row applies its
/// plan only when its state changes, so an animation that was refused (loops off for a moment) or
/// lost while the plan stayed the same used to stay gone: the row drew the still arc until its
/// state changed. Applying the same plan again, or the app coming back to the front, restores it
/// (for the indicators on screen; per window, StatusIndicatorWindowResyncTests).
@MainActor @Suite(.serialized) struct StatusIndicatorRepairTests {
    static let spin = StatusIndicatorPlan(glyph: .arc, animation: .spin, tint: .loading)

    static func indicator() -> StatusIndicatorLayer {
        let indicator = StatusIndicatorLayer(clock: SpinnerClock(mediaTime: { 100 }, unixTime: { 1_000 }))
        indicator.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
        return indicator
    }

    @Test func applyingTheSamePlanRestoresALostSpin() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let indicator = Self.indicator()
        indicator.apply(Self.spin, config: StatusIndicatorConfig())
        #expect(indicator.runningAnimation == .spin)
        indicator.glyphLayer?.removeAnimation(forKey: "spin")
        #expect(indicator.runningAnimation == nil)
        indicator.apply(Self.spin, config: StatusIndicatorConfig())
        #expect(indicator.runningAnimation == .spin)
    }

    @Test func aSpinTheMotionGateRefusedStartsWhenLoopsReturn() {
        let indicator = Self.indicator()
        Motion.reduceMotionOverride = true
        indicator.apply(Self.spin, config: StatusIndicatorConfig())
        #expect(indicator.runningAnimation == nil)
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        indicator.apply(Self.spin, config: StatusIndicatorConfig())
        #expect(indicator.runningAnimation == .spin)
    }

    @Test func aSpinningMarkReadsAsRunning() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let indicator = Self.indicator()
        indicator.apply(StatusIndicatorPlan(glyph: .mark(.vector(.idle)), animation: .spin, tint: .accent),
                        config: StatusIndicatorConfig())
        #expect(indicator.markLayer?.animation(forKey: "spin") != nil)
        #expect(indicator.runningAnimation == .spin)
    }

    @Test(arguments: [NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification,
                      NSWindow.didBecomeMainNotification])
    func theAppComingBackResyncsTheIndicatorsOnScreen(_ name: Notification.Name) {
        let app = NotificationCenter()
        let (window, client) = Self.shownClient(app: app, workspace: NotificationCenter())
        defer { window.close() }
        app.post(name: name, object: name == NSWindow.didBecomeMainNotification ? window : nil)
        #expect(client.resyncs == 1)
    }

    @Test(arguments: [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification])
    func wakingFromSleepResyncsTheIndicatorsOnScreen(_ name: Notification.Name) {
        let workspace = NotificationCenter()
        let (window, client) = Self.shownClient(app: NotificationCenter(), workspace: workspace)
        defer { window.close() }
        workspace.post(name: name, object: nil)
        #expect(client.resyncs == 1)
    }

    /// A resync host shown in a window that is on screen, its notices on `app` and `workspace`.
    private static func shownClient(app: NotificationCenter, workspace: NotificationCenter) -> (NSWindow, ResyncCounter) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        _ = WindowKeyFamily.of(window, environment: WindowKeyEnvironment(
            center: app, keyWindow: { nil }, isAppActive: { true }, nextTurn: { _ in },
            workspaceCenter: workspace, isWindowVisible: { _ in true }))
        let client = ResyncCounter()
        client.placement.update(client, in: window, shown: true)
        return (window, client)
    }
}

@MainActor private final class ResyncCounter: StatusIndicatorResyncClient {
    let placement = StatusIndicatorPlacement()
    var resyncs = 0
    func statusIndicatorResync() { resyncs += 1 }
}
