import AppKit
@testable import CmuxNextDesign
import Testing

/// A spinner that stopped comes back on its own (Leo 2026-10-20, ~17 sidebar rows with a still
/// arc: "why do these things not spin? Why have they not spun for a while?"). A row applies its
/// plan only when its state changes, so an animation that was refused (loops off for a moment) or
/// lost while the plan stayed the same used to stay gone: the row drew the still arc until its
/// state changed. Applying the same plan again, or the app coming back to the front, restores it.
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
    func theAppComingBackResyncsEveryIndicator(_ name: Notification.Name) {
        let app = NotificationCenter()
        let appearance = StatusIndicatorAppearance(appCenter: app, workspaceCenter: NotificationCenter())
        let client = ResyncCounter()
        appearance.register(client)
        appearance.setFollowsResyncs(client, follows: true) // on screen: the moments reach it
        app.post(name: name, object: nil)
        #expect(client.resyncs == 1)
    }

    @Test(arguments: [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification])
    func wakingFromSleepResyncsEveryIndicator(_ name: Notification.Name) {
        let workspace = NotificationCenter()
        let appearance = StatusIndicatorAppearance(appCenter: NotificationCenter(), workspaceCenter: workspace)
        let client = ResyncCounter()
        appearance.register(client)
        appearance.setFollowsResyncs(client, follows: true) // on screen: the moments reach it
        workspace.post(name: name, object: nil)
        #expect(client.resyncs == 1)
    }
}

@MainActor private final class ResyncCounter: StatusIndicatorConfigClient {
    var resyncs = 0
    func statusIndicatorConfigDidChange(_ config: StatusIndicatorConfig) {}
    func statusIndicatorResync() { resyncs += 1 }
}
