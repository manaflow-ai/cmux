import AppKit
import CmuxNextFocusUI
import Testing

/// The one owned queue of a window's held keys (principled audit, lagFirstKey): each key goes exactly once, in typed
/// order, to the target it was typed for, when that target takes keys, or drops with a reason; nothing else.
@MainActor @Suite
struct WindowInputQueueTests {
    private static var timestamp: TimeInterval = 21_000

    private static func key(_ characters: String) throws -> NSEvent {
        timestamp += 0.01
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp, windowNumber: 0,
                                             context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                             isARepeat: false, keyCode: 0))
    }

    private let terminal = WindowInputQueue.Target("tab-new")
    private let other = WindowInputQueue.Target("tab-other")

    @Test func keysGoOnlyToTheirTargetInTypedOrderWhenItTakesKeys() throws {
        let queue = WindowInputQueue(dropped: { _, _, _ in })
        for letter in ["a", "b"] { queue.capture(try Self.key(letter), for: terminal) }
        queue.capture(try Self.key("x"), for: other)
        queue.capture(try Self.key("c"), for: terminal)

        var sent: [String] = []
        #expect(queue.drain(terminal, takesKeys: { false }) { sent.append($0.characters ?? "") } == 0, "keys went while the target took none")
        #expect(queue.drain(terminal, takesKeys: { true }) { sent.append($0.characters ?? "") } == 3)
        #expect(sent == ["a", "b", "c"], "the target's keys did not go in typed order, or another target's key went with them")
        #expect(queue.waiting(for: other) == 1)
        #expect(queue.problems.isEmpty, "\(queue.problems)")
    }

    @Test func aDeliveredKeyThatMovesTheKeyboardStopsTheRun() throws {
        let queue = WindowInputQueue(dropped: { _, _, _ in })
        for letter in ["a", "b", "c"] { queue.capture(try Self.key(letter), for: terminal) }
        var takes = true
        var sent: [String] = []
        queue.drain(terminal, takesKeys: { takes }) { event in
            sent.append(event.characters ?? "")
            takes = false // the first key (a Ctrl-2 onto a cold tab) moves the keyboard away
        }
        #expect(sent == ["a"])
        #expect(queue.waiting(for: terminal) == 2, "the keys after the move did not wait")
        takes = true
        queue.drain(terminal, takesKeys: { takes }) { sent.append($0.characters ?? "") }
        #expect(sent == ["a", "b", "c"])
        #expect(queue.problems.isEmpty, "\(queue.problems)")
    }

    @Test func aKeyHeldAgainWhileItRunsWaitsBehindTheRest() throws {
        let queue = WindowInputQueue(dropped: { _, _, _ in })
        for letter in ["a", "b"] { queue.capture(try Self.key(letter), for: terminal) }
        var sent: [String] = []
        var heldAgain = false
        let again = try Self.key("z")
        queue.drain(terminal, takesKeys: { true }) { event in
            sent.append(event.characters ?? "")
            if !heldAgain { heldAgain = true; queue.capture(again, for: terminal) }
        }
        #expect(sent == ["a", "b", "z"])
        #expect(queue.problems.isEmpty, "\(queue.problems)")
    }

    @Test func aClosedOrFailedTargetDropsItsKeysWithAReasonAndNoOtherTargetGetsThem() throws {
        var drops: [(String, WindowInputQueue.DropReason, Int)] = []
        let queue = WindowInputQueue(dropped: { drops.append(($0.id, $1, $2)) })
        for letter in ["a", "b"] { queue.capture(try Self.key(letter), for: terminal) }
        queue.capture(try Self.key("x"), for: other)
        #expect(queue.drop(terminal, .targetFailed) == 2)
        #expect(drops.count == 1 && drops[0].0 == "tab-new" && drops[0].1 == .targetFailed && drops[0].2 == 2)
        var sent: [String] = []
        queue.drain(other, takesKeys: { true }) { sent.append($0.characters ?? "") }
        #expect(sent == ["x"], "a dropped target's key went to another target")
        #expect(queue.counts == WindowInputQueue.Counts(captured: 3, delivered: 1, dropped: 2))
        #expect(queue.problems.isEmpty, "\(queue.problems)")
    }

    @Test func anAdoptedStandInKeepsItsKeysAndTheirOrder() throws {
        let queue = WindowInputQueue(dropped: { _, _, _ in })
        let real = WindowInputQueue.Target("tab-daemon")
        queue.capture(try Self.key("a"), for: terminal)
        queue.retarget(terminal, to: real)
        queue.capture(try Self.key("b"), for: real)
        var sent: [String] = []
        queue.drain(real, takesKeys: { true }) { sent.append($0.characters ?? "") }
        #expect(sent == ["a", "b"])
        #expect(queue.waiting(for: terminal) == 0)
        #expect(queue.problems.isEmpty, "\(queue.problems)")
    }

    @Test func closingTheWindowFreesEveryWaitingKey() throws {
        var reasons: [WindowInputQueue.DropReason] = []
        let queue = WindowInputQueue(dropped: { _, reason, _ in reasons.append(reason) })
        queue.capture(try Self.key("a"), for: terminal)
        queue.capture(try Self.key("x"), for: other)
        queue.close()
        #expect(queue.isEmpty)
        #expect(reasons == [.windowClosed, .windowClosed])
        #expect(queue.counts == WindowInputQueue.Counts(captured: 2, delivered: 0, dropped: 2))
        #expect(queue.problems.isEmpty, "\(queue.problems)")
    }
}
