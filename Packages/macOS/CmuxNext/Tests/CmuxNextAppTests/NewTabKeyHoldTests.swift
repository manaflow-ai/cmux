import AppKit
import CmuxNextFocusUI
import Testing

/// The held New Tab key's state alone (`NewTabKeyHold`, decision 2026-11-16), with events made here: what begins a
/// hold, which events end it, and that its end runs once. No app, no page and no engine: `NewTabRepeatKeyTests`
/// holds the rule in the app.
@MainActor @Suite struct NewTabKeyHoldTests {
    private static func key(_ type: NSEvent.EventType, code: UInt16 = 17, repeats: Bool = false,
                            flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        let text = type == .flagsChanged ? "" : "t"
        return try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                             characters: text, charactersIgnoringModifiers: text, isARepeat: repeats, keyCode: code))
    }

    /// A hold of T with Command, begun by a repeat; `ends` counts the runs of its end.
    private static func heldCommandT() throws -> (hold: NewTabKeyHold, ends: () -> Int) {
        let hold = NewTabKeyHold()
        var ends = 0
        try #require(hold.begin(at: try key(.keyDown, repeats: true)) { ends += 1 }, "a repeat began no hold")
        return (hold, { ends })
    }

    @Test func onlyARepeatBeginsAHold() throws {
        let hold = NewTabKeyHold()
        var ends = 0
        #expect(!hold.begin(at: nil) { ends += 1 }, "no event in dispatch began a hold")
        #expect(!hold.begin(at: try Self.key(.keyDown)) { ends += 1 }, "a key-down with no repeat flag began a hold")
        #expect(!hold.begin(at: try Self.key(.keyUp)) { ends += 1 }, "a key-up began a hold")
        #expect(!hold.isOn)
        #expect(hold.begin(at: try Self.key(.keyDown, repeats: true)) { ends += 1 }, "a repeat began no hold")
        #expect(hold.isOn)
        #expect(ends == 0, "an end ran with no end event")
        let repeatDown = try Self.key(.keyDown, repeats: true), down = try Self.key(.keyDown), up = try Self.key(.keyUp)
        #expect(NewTabKeyHold.isRepeat(repeatDown), "a key-down with the repeat flag is no repeat")
        #expect(!NewTabKeyHold.isRepeat(down) && !NewTabKeyHold.isRepeat(up) && !NewTabKeyHold.isRepeat(nil), "a press, a key-up or no event is a repeat")
    }

    @Test func eachEndEventEndsTheHoldAndRunsItsEndOnce() throws {
        let ends: [(String, NSEvent)] = [
            ("the key-up of the held key", try Self.key(.keyUp)),
            ("the key-up of the held key with Command already up", try Self.key(.keyUp, flags: [])),
            ("Command up", try Self.key(.flagsChanged, code: 55, flags: [])),
            ("Command up with Shift down", try Self.key(.flagsChanged, code: 55, flags: .shift)),
            ("another key", try Self.key(.keyDown, code: 0)),
            ("a new press of the same key", try Self.key(.keyDown)),
            ("a repeat of another key", try Self.key(.keyDown, code: 0, repeats: true)),
        ]
        for (name, event) in ends {
            let (hold, count) = try Self.heldCommandT()
            hold.note(event)
            #expect(!hold.isOn, "\(name) did not end the hold")
            #expect(count() == 1, "the end ran \(count()) times at \(name)")
            hold.note(event)
            hold.end()
            #expect(count() == 1, "the end ran again after the hold's end (\(name))")
        }
        let (hold, count) = try Self.heldCommandT()
        hold.end()
        #expect(!hold.isOn && count() == 1, "the app's own end (no longer active) ran the end \(count()) times")
    }

    @Test func anEventThatIsNoEndKeepsTheHold() throws {
        let (hold, count) = try Self.heldCommandT()
        hold.note(try Self.key(.keyDown, repeats: true))
        hold.note(try Self.key(.keyUp, code: 0))
        hold.note(try Self.key(.flagsChanged, code: 56, flags: [.command, .shift]))
        hold.note(try Self.key(.flagsChanged, code: 56, flags: .command))
        let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                    eventNumber: 0, clickCount: 0, pressure: 0))
        hold.note(moved)
        #expect(hold.isOn, "an event that is no end ended the hold")
        #expect(count() == 0, "the end ran \(count()) times with the key still down")
    }

    /// Each repeat's opening replaces the end of the one before: the end runs for the last opening only.
    @Test func theEndOfAHoldIsTheLastOpenings() throws {
        let hold = NewTabKeyHold()
        var ran: [Int] = []
        let repeatDown = try Self.key(.keyDown, repeats: true)
        for opening in 1...3 { hold.begin(at: repeatDown) { ran.append(opening) } }
        hold.note(try Self.key(.keyUp))
        #expect(ran == [3], "the ends that ran: \(ran)")
    }

    /// A key with no modifier (a rebound New Tab key): a flags event ends nothing, its key-up does.
    @Test func aHeldKeyWithNoModifierEndsAtItsKeyUp() throws {
        let hold = NewTabKeyHold()
        var ends = 0
        hold.begin(at: try Self.key(.keyDown, repeats: true, flags: [])) { ends += 1 }
        hold.note(try Self.key(.flagsChanged, code: 56, flags: .shift))
        hold.note(try Self.key(.flagsChanged, code: 56, flags: []))
        #expect(hold.isOn && ends == 0, "a flags event ended the hold of a key with no modifier")
        hold.note(try Self.key(.keyUp, flags: []))
        #expect(!hold.isOn && ends == 1)
    }
}
