import AppKit
import CmuxNextFocusUI
import Testing

/// The held New Tab key's state alone (`NewTabKeyHold`, decision 2026-11-16), with events made here: what begins a
/// hold, which events end it, that its end runs once for each owner that waits, and which repeat begins no hold.
/// No app, no page and no engine: `NewTabRepeatKeyTests` holds the rule in the app.
@MainActor @Suite struct NewTabKeyHoldTests {
    /// What waits for a hold's end: a pane in the app.
    private final class Owner {}

    private static func key(_ type: NSEvent.EventType, code: UInt16 = 17, repeats: Bool = false,
                            flags: NSEvent.ModifierFlags = .command, at time: TimeInterval = 0) throws -> NSEvent {
        let text = type == .flagsChanged ? "" : "t"
        return try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: time, windowNumber: 0, context: nil,
                                             characters: text, charactersIgnoringModifiers: text, isARepeat: repeats, keyCode: code))
    }

    /// A hold of T with Command, begun by a repeat for `owner`; `ends` counts the runs of its end.
    private static func heldCommandT(for owner: Owner) throws -> (hold: NewTabKeyHold, ends: () -> Int) {
        let hold = NewTabKeyHold()
        var ends = 0
        try #require(hold.begin(at: try key(.keyDown, repeats: true), for: owner) { ends += 1 }, "a repeat began no hold")
        return (hold, { ends })
    }

    @Test func onlyARepeatBeginsAHold() throws {
        let hold = NewTabKeyHold(), owner = Owner()
        var ends = 0
        #expect(!hold.begin(at: nil, for: owner) { ends += 1 }, "no event in dispatch began a hold")
        #expect(!hold.begin(at: try Self.key(.keyDown), for: owner) { ends += 1 }, "a key-down with no repeat flag began a hold")
        #expect(!hold.begin(at: try Self.key(.keyUp), for: owner) { ends += 1 }, "a key-up began a hold")
        #expect(!hold.isOn)
        #expect(hold.begin(at: try Self.key(.keyDown, repeats: true), for: owner) { ends += 1 }, "a repeat began no hold")
        #expect(hold.isOn)
        #expect(ends == 0, "an end ran with no end event")
        let repeatDown = try Self.key(.keyDown, repeats: true), down = try Self.key(.keyDown), up = try Self.key(.keyUp)
        #expect(NewTabKeyHold.isRepeat(repeatDown), "a key-down with the repeat flag is no repeat")
        #expect(!NewTabKeyHold.isRepeat(down) && !NewTabKeyHold.isRepeat(up) && !NewTabKeyHold.isRepeat(nil), "a press, a key-up or no event is a repeat")
    }

    @Test func eachEndEventEndsTheHoldAndRunsItsEndOnce() throws {
        let owner = Owner()
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
            let (hold, count) = try Self.heldCommandT(for: owner)
            hold.note(event)
            #expect(!hold.isOn, "\(name) did not end the hold")
            #expect(count() == 1, "the end ran \(count()) times at \(name)")
            hold.note(event)
            hold.end()
            hold.resigned()
            #expect(count() == 1, "the end ran again after the hold's end (\(name))")
        }
        let (hold, count) = try Self.heldCommandT(for: owner)
        hold.resigned()
        #expect(!hold.isOn && count() == 1, "the app's own end (no longer active) ran the end \(count()) times")
    }

    @Test func anEventThatIsNoEndKeepsTheHold() throws {
        let owner = Owner()
        let (hold, count) = try Self.heldCommandT(for: owner)
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

    /// Each repeat's opening replaces its owner's end of the one before: the end runs for the owner's last opening
    /// only.
    @Test func theEndOfAHoldIsItsOwnersLastOpenings() throws {
        let hold = NewTabKeyHold(), owner = Owner()
        var ran: [Int] = []
        let repeatDown = try Self.key(.keyDown, repeats: true)
        for opening in 1...3 { hold.begin(at: repeatDown, for: owner) { ran.append(opening) } }
        hold.note(try Self.key(.keyUp))
        #expect(ran == [3], "the ends that ran: \(ran)")
    }

    /// The hold is one for all owners. An owner that asks while it is on waits too, also when it began no hold;
    /// the end runs each owner's end once, in the order of each owner's first wait.
    @Test func theEndOfAHoldRunsTheEndOfEachOwnerThatWaits() throws {
        let hold = NewTabKeyHold(), owners = [Owner(), Owner(), Owner()]
        var ran: [String] = []
        #expect(!hold.holds(owners[1]) { ran.append("asked with no hold") }, "an owner waits for a hold that is not on")
        let repeatDown = try Self.key(.keyDown, repeats: true)
        hold.begin(at: repeatDown, for: owners[0]) { ran.append("first, opening 1") }
        #expect(hold.holds(owners[1]) { ran.append("second, asked 1") }, "an owner does not wait for a hold that is on")
        #expect(!hold.begin(at: nil, for: owners[2]) { ran.append("third, no event") }, "no event in dispatch began a hold")
        hold.begin(at: repeatDown, for: owners[0]) { ran.append("first, opening 2") }
        #expect(hold.holds(owners[1]) { ran.append("second, asked 2") }, "an owner does not wait for a hold that is on")
        #expect(ran.isEmpty, "an end ran with the key still down: \(ran)")
        hold.note(try Self.key(.keyUp))
        #expect(ran == ["first, opening 2", "second, asked 2"], "the ends that ran: \(ran)")
        // The next hold has none of the ends before.
        hold.begin(at: repeatDown, for: owners[2]) { ran.append("third, opening 1") }
        hold.note(try Self.key(.keyUp))
        #expect(ran == ["first, opening 2", "second, asked 2", "third, opening 1"], "the ends that ran after a second hold: \(ran)")
        #expect(!hold.holds(owners[0]) { ran.append("asked after the end") }, "an owner waits after the hold's end")
    }

    /// The app can get a repeat again later than the system made it. A repeat that is older than the newest event
    /// that can end a hold (a key-up, a flags event, a key-down with no repeat flag; of any key) begins no hold: no
    /// later event ends it. A repeat that is not older begins one.
    @Test func aRepeatOlderThanAnEventThatCanEndAHoldBeginsNone() throws {
        let owner = Owner()
        let ends: [(String, NSEvent)] = [
            ("the key-up of its key", try Self.key(.keyUp, at: 20)),
            ("the key-up of another key", try Self.key(.keyUp, code: 0, at: 20)),
            ("Command up", try Self.key(.flagsChanged, code: 55, flags: [], at: 20)),
            ("Shift down", try Self.key(.flagsChanged, code: 56, flags: [.command, .shift], at: 20)),
            ("a press of its key", try Self.key(.keyDown, at: 20)),
            ("a press of another key", try Self.key(.keyDown, code: 0, at: 20)),
        ]
        for (name, event) in ends {
            let hold = NewTabKeyHold()
            var ran = 0
            hold.note(try Self.key(.keyDown, repeats: true, at: 10)) // the app got the repeat once, in the system's order
            hold.note(event)
            #expect(!hold.begin(at: try Self.key(.keyDown, repeats: true, at: 10), for: owner) { ran += 1 }, "a repeat older than \(name) began a hold")
            #expect(!hold.isOn, "a hold is on after a repeat older than \(name)")
            // An older event that the app gets again moves nothing back.
            hold.note(try Self.key(.keyUp, at: 5))
            #expect(!hold.begin(at: try Self.key(.keyDown, repeats: true, at: 19), for: owner) { ran += 1 }, "a repeat older than \(name) began a hold")
            #expect(hold.begin(at: try Self.key(.keyDown, repeats: true, at: 20), for: owner) { ran += 1 }, "a repeat of the same time as \(name) began no hold")
            #expect(hold.begin(at: try Self.key(.keyDown, repeats: true, at: 30), for: owner) { ran += 1 }, "a repeat newer than \(name) began no hold")
            #expect(ran == 0, "an end ran with the key still down (\(name))")
        }
        // No event that can end a hold: a repeat, and an event of the mouse.
        let hold = NewTabKeyHold()
        hold.note(try Self.key(.keyDown, repeats: true, at: 20))
        hold.note(try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 20, windowNumber: 0, context: nil,
                                                  eventNumber: 0, clickCount: 0, pressure: 0)))
        #expect(hold.begin(at: try Self.key(.keyDown, repeats: true, at: 10), for: owner) {}, "a repeat older than a repeat or a mouse event began no hold")
    }

    /// A refused repeat changes nothing of a hold that is on: the hold goes on, with the ends that it had.
    @Test func aRefusedRepeatLeavesAHoldThatIsOn() throws {
        let hold = NewTabKeyHold(), owners = [Owner(), Owner()]
        var ran: [String] = []
        hold.note(try Self.key(.keyUp, code: 0, at: 20))
        hold.begin(at: try Self.key(.keyDown, repeats: true, at: 30), for: owners[0]) { ran.append("first") }
        #expect(!hold.begin(at: try Self.key(.keyDown, repeats: true, at: 10), for: owners[1]) { ran.append("second, refused") }, "a repeat older than a key-up began a hold")
        #expect(hold.isOn, "a refused repeat ended the hold")
        hold.note(try Self.key(.keyUp, at: 40))
        #expect(ran == ["first"], "the ends that ran: \(ran)")
    }

    /// The app resigned: the key-up of a held key goes to another app. A repeat that the app got before, and gets
    /// again after, begins no hold; a repeat newer than each event before the resign begins one.
    @Test func afterAResignARepeatThatTheAppGotBeforeBeginsNoHold() throws {
        let hold = NewTabKeyHold(), owner = Owner()
        var ran = 0
        let kept = try Self.key(.keyDown, repeats: true, at: 10)
        hold.note(kept)
        hold.resigned()
        #expect(!hold.begin(at: kept, for: owner) { ran += 1 }, "a repeat that the app got before it resigned began a hold")
        #expect(!hold.isOn)
        #expect(hold.begin(at: try Self.key(.keyDown, repeats: true, at: 11), for: owner) { ran += 1 }, "a repeat newer than the resign began no hold")
        hold.resigned()
        #expect(!hold.isOn && ran == 1, "the resign ran the end \(ran) times")
        // A hold with a repeat at time 0 (no event noted before): a resign with no event before it refuses nothing newer.
        let fresh = NewTabKeyHold()
        fresh.resigned()
        #expect(fresh.begin(at: try Self.key(.keyDown, repeats: true, at: 1), for: owner) {}, "a resign with no event before it refused a repeat")
    }

    /// A key with no modifier (a rebound New Tab key): a flags event ends nothing, its key-up does.
    @Test func aHeldKeyWithNoModifierEndsAtItsKeyUp() throws {
        let hold = NewTabKeyHold(), owner = Owner()
        var ends = 0
        hold.begin(at: try Self.key(.keyDown, repeats: true, flags: []), for: owner) { ends += 1 }
        hold.note(try Self.key(.flagsChanged, code: 56, flags: .shift))
        hold.note(try Self.key(.flagsChanged, code: 56, flags: []))
        #expect(hold.isOn && ends == 0, "a flags event ended the hold of a key with no modifier")
        hold.note(try Self.key(.keyUp, flags: []))
        #expect(!hold.isOn && ends == 1)
    }
}
