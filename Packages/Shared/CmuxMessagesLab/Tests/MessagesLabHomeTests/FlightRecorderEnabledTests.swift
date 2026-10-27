import AppKit
import Testing
@testable import MessagesLabHome

/// The flight recorder costs nothing while its policy is off (p14-energy-051): no display link, no dump and
/// so no capture burst. It reads the policy live, so a link that runs when the policy turns off stops on its
/// next frame. Each test gives its own recorder its own policy (the app's `shared` reads HomeFlightRecorder).
@MainActor @Suite struct FlightRecorderEnabledTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    @MainActor final class Policy {
        var on: Bool
        init(_ on: Bool) { self.on = on }
    }

    /// A controller in an offscreen window, before any transcript is installed.
    private func makePane() -> (window: NSWindow, controller: ChatController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        window.contentView = controller.host
        return (window, controller)
    }

    @Test func offMakesNoLinkAndNoDump() {
        let policy = Policy(false)
        let recorder = FlightRecorder(isEnabled: { policy.on })
        let pane = makePane()
        recorder.attach(pane.controller)

        recorder.action(.send)
        #expect(!recorder.isSampling, "a send while off makes no display link")
        recorder.kick()
        #expect(!recorder.isSampling, "a kick while off makes no display link")
        recorder.saveLastSeconds(nil)
        #expect(recorder.dumps.isEmpty, "off, Save Last 10 Seconds writes nothing and schedules no capture burst")
        withExtendedLifetime(pane.window) {}
    }

    @Test func aRunningLinkStopsOnItsNextFrameOnceThePolicyIsOff() {
        let policy = Policy(true)
        let recorder = FlightRecorder(isEnabled: { policy.on })
        let pane = makePane()
        recorder.attach(pane.controller)

        recorder.kick()
        #expect(recorder.isSampling, "on, a kick starts sampling")
        policy.on = false
        recorder.displayFrame()
        #expect(!recorder.isSampling, "the first frame after the policy turns off stops the link")
        recorder.kick()
        #expect(!recorder.isSampling)
        withExtendedLifetime(pane.window) {}
    }

    @Test func aPaneWithNoTranscriptStopsTheLink() {
        let recorder = FlightRecorder(isEnabled: { true })
        let pane = makePane()
        recorder.attach(pane.controller)

        recorder.kick()
        #expect(recorder.isSampling)
        recorder.displayFrame()
        #expect(!recorder.isSampling, "nothing to sample: the link stops instead of firing every frame")
        withExtendedLifetime(pane.window) {}
    }
}
