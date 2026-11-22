import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// MessagesLab bd65bbf (Engine.dispatchAhead): a keystroke goes first. In
/// Home the jobs that would share the keystroke's frame are HomeStore's
/// ambient updates (statuses, typing): during a keystroke frame they wait for
/// the start of the next display frame; a received message is never held.
@MainActor @Suite(.serialized) struct KeystrokeAheadTests {
    let me = Fixture2.me, them = Fixture2.them

    @Test func aStatusInAKeystrokeFrameWaitsForTheNextFrame() {
        let (p, c) = Fixture2.projection()
        c.host.layoutSubtreeIfNeeded()
        var frames: [() -> Void] = []
        c.nextFrame = { frames.append($0) }
        var mine = Fixture2.item(2, me, "Sent", key: "k2")
        mine.delivery = .committed
        p.apply(items: [Fixture2.item(1, them, "Hi"), mine], summary: Fixture2.summary(lastSeq: 2), typing: [], hasOlder: false)
        // The user types: the field's change is a keystroke.
        c.dispatch(.setDraft("H"))
        #expect(c.inKeystrokeFrame)
        let keystrokeFrames = frames.count  // the keystroke frame's own end
        // The Chief reads my message in the same frame: only a status change.
        p.apply(items: [Fixture2.item(1, them, "Hi"), mine], summary: Fixture2.summary(lastSeq: 2, read: 2), typing: [them], hasOlder: false)
        #expect(c.store!.state.ui.typing.isEmpty, "typing waits for the next frame")
        if case .read = c.store!.state.message("k2")?.status { Issue.record("the read status waited for the next frame") }
        #expect(frames.count == keystrokeFrames + 1, "one held commit")
        frames.forEach { $0() }
        #expect(c.store!.state.ui.typing == [them.rawValue])
        if case .read = c.store!.state.message("k2")?.status {} else { Issue.record("read after the frame, got \(String(describing: c.store!.state.message("k2")?.status))") }
    }

    @Test func aReceivedMessageIsNeverHeld() {
        let (p, c) = Fixture2.projection()
        c.host.layoutSubtreeIfNeeded()
        var frames: [() -> Void] = []
        c.nextFrame = { frames.append($0) }
        p.apply(items: [Fixture2.item(1, them, "Hi")], summary: Fixture2.summary(lastSeq: 1), typing: [], hasOlder: false)
        c.dispatch(.setDraft("H"))
        let keystrokeFrames = frames.count
        p.apply(items: [Fixture2.item(1, them, "Hi"), Fixture2.item(2, them, "There")], summary: Fixture2.summary(lastSeq: 2), typing: [], hasOlder: false)
        #expect(c.store!.state.conversation.messages.count == 2)
        #expect(frames.count == keystrokeFrames, "nothing held")
    }
}
