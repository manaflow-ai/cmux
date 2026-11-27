import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// Home looks the same when its window or tab is not focused (Lawrence 2026-10-18: "imessage home ui should not
/// have different appearance when imessage tab is not focused"). MessagesLab greys its window view (the typing
/// indicator and the lights, MessagesLab 806ef0c) when that window resigns key; cmux keeps the key look unless
/// `--follow-key-state` asks for MessagesLab's parity behavior.
@MainActor @Suite(.serialized) struct HomeUnfocusedAppearanceTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")

    /// A Home pane over a loaded conversation in an offscreen window that is never key.
    private func pane(followsKeyWindow: Bool) -> (NSWindow, ChatController) {
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
        controller.followsKeyWindow = followsKeyWindow
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    @Test func theInactiveStateNeedsTheParitySwitch() {
        #expect(!ChatController.viewInactive(followsKeyWindow: false, windowIsKey: false))
        #expect(!ChatController.viewInactive(followsKeyWindow: false, windowIsKey: true))
        #expect(ChatController.viewInactive(followsKeyWindow: true, windowIsKey: false))
        #expect(!ChatController.viewInactive(followsKeyWindow: true, windowIsKey: true))
    }

    @Test(arguments: [false, true])
    func aHomeInAWindowThatIsNotKeyKeepsTheKeyLook(light: Bool) throws {
        let saved = Fixture.lightAppearance
        defer { Fixture.lightAppearance = saved }
        let (window, controller) = pane(followsKeyWindow: false)
        defer { window.close() }
        let demo = try #require(controller.demo)
        demo.setLightAppearance(light)
        #expect(window.isKeyWindow == false)
        let keyBackground = Fixture.background
        controller.followKeyState()
        #expect(demo.inactive == false, "Home greyed its view in a window that is not key")
        #expect(demo.backgroundColor == keyBackground)
        let key = Fixture.typingColors(inactive: false)
        #expect(Fixture.typingColors(inactive: demo.inactive).fill == key.fill)
    }

    @Test func theParitySwitchGreysOnlyItsOwnView() throws {
        let (window, controller) = pane(followsKeyWindow: true)
        defer { window.close() }
        let (other, steady) = pane(followsKeyWindow: false)
        defer { other.close() }
        controller.followKeyState()
        steady.followKeyState()
        #expect(try #require(controller.demo).inactive == true)
        #expect(try #require(steady.demo).inactive == false)
    }
}
