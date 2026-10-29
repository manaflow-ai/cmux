import AppKit
import CmuxHomeCore
import CmuxHomeRender
import Testing
@testable import MessagesLabHome

/// The flight recorder costs nothing while its policy is off: no display link, no dump and
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

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")

    /// A controller in an offscreen window; with `transcript`, a two-message conversation is installed
    /// (so `ChatController.demo` exists and a frame has something to sample), as ComposeVoiceTests does.
    private func makePane(transcript: Bool = false) -> (window: NSWindow, controller: ChatController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        window.contentView = controller.host
        if transcript {
            let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                          CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            let items = (1...2).map { i in
                TranscriptItem(key: IdempotencyKey("k\(i)"), seq: Seq(i), author: i % 2 == 0 ? Self.me : Self.them,
                               parts: [.text("Message number \(i)")], createdAt: base.addingTimeInterval(Double(i)),
                               delivery: .committed, messageID: MessageID("msg_\(i)"))
            }
            let summary = ConversationSummary(id: ConversationID("conv_flight"), title: "Chief", participants: people, lastSeq: 2,
                                              createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
            var core = ProjectionCore(me: Self.me)
            let (conv, w) = core.install(ConversationID("conv_flight"), items: items, summary: summary)
            controller.install(conv, windowStart: w.start, total: w.total)
            controller.host.layoutSubtreeIfNeeded()
        }
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

    /// A pane with a transcript, busy for 10 s after a send: only the policy can stop its link, so this
    /// fails if `displayFrame` stops reading it.
    @Test func aRunningLinkStopsOnItsNextFrameOnceThePolicyIsOff() {
        let policy = Policy(true)
        let recorder = FlightRecorder(isEnabled: { policy.on })
        let pane = makePane(transcript: true)
        recorder.attach(pane.controller)
        #expect(pane.controller.demo != nil, "the pane has a transcript to sample")

        recorder.action(.send)
        #expect(recorder.isSampling, "on, a send starts sampling")
        recorder.displayFrame()
        #expect(recorder.isSampling, "on and within 10 s of a send, a frame keeps the link")
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
