import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// Home looks the same when its window or tab is not focused (Lawrence 2026-10-18: "imessage home ui should not
/// have different appearance when imessage tab is not focused"). MessagesLab switches to Messages' inactive-window
/// palette (lighter background, other bubble colours, grey lights) when its window resigns key; cmux keeps the key
/// palette unless `--follow-key-state` asks for MessagesLab's parity behavior.
@MainActor @Suite(.serialized) struct HomeUnfocusedAppearanceTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")

    /// A Home pane over a loaded conversation in an offscreen window that is never key.
    private func pane() -> (NSWindow, ChatController) {
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = (1...4).map { i in
            TranscriptItem(key: IdempotencyKey("k\(i)"), seq: Seq(i), author: i % 2 == 0 ? Self.me : Self.them,
                           parts: [.text("Message \(i)")], createdAt: base.addingTimeInterval(Double(i)),
                           delivery: .committed, messageID: MessageID("msg_\(i)"))
        }
        let summary = ConversationSummary(id: ConversationID("conv_unfocused"), title: "Chief", participants: people, lastSeq: 4,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(ConversationID("conv_unfocused"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    @Test func theInactivePaletteNeedsTheParitySwitch() {
        #expect(!HomeKeyState.paletteInactive(followsKeyWindow: false, keyWindowShowsHome: false))
        #expect(!HomeKeyState.paletteInactive(followsKeyWindow: false, keyWindowShowsHome: true))
        #expect(HomeKeyState.paletteInactive(followsKeyWindow: true, keyWindowShowsHome: false))
        #expect(!HomeKeyState.paletteInactive(followsKeyWindow: true, keyWindowShowsHome: true))
    }

    @Test(arguments: [false, true])
    func aHomeInAWindowThatIsNotKeyKeepsTheKeyPalette(light: Bool) throws {
        let state = HomeKeyState.shared
        let saved = (state.followsKeyWindow, Fixture.inactive, Fixture.lightAppearance)
        defer { state.followsKeyWindow = saved.0; Fixture.inactive = saved.1; Fixture.lightAppearance = saved.2 }
        let (window, controller) = pane()
        defer { window.close() }
        let demo = try #require(controller.demo)
        demo.setLightAppearance(light)
        state.register(controller)
        #expect(window.isKeyWindow == false)

        state.followsKeyWindow = false
        demo.setInactive(false)
        let keyBackground = Fixture.background
        state.apply()
        #expect(Fixture.inactive == false, "Home switched to the inactive palette in a window that is not key")
        #expect(Fixture.background == keyBackground)
        #expect(demo.backgroundColor == keyBackground)

        // The parity switch still gives MessagesLab's inactive window.
        state.followsKeyWindow = true
        state.apply()
        #expect(Fixture.inactive == true)
    }
}
