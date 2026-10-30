import AppKit
import CmuxNextRemoteView
import CoreGraphics
import Testing

/// "Send System Shortcuts to the Remote Mac": the session event tap exists
/// only while every condition holds, takes exactly the system chords (never
/// the release chord, never ordinary typing, and the system list over cmux's
/// own bindings), and turns what it takes into the same key events the
/// capture view sends.
struct MacScreenSystemShortcutTapTests {
    private let policy = RemoteSystemShortcuts()
    private let all = RemoteSystemShortcuts.Conditions(setting: true, accessibility: true, hasKeyboard: true, live: true,
                                                       windowKey: true, appActive: true)

    @Test func installsOnlyWhileEveryConditionHolds() {
        #expect(policy.installs(all))
        let each: [WritableKeyPath<RemoteSystemShortcuts.Conditions, Bool>] = [
            \.setting, \.accessibility, \.hasKeyboard, \.live, \.windowKey, \.appActive,
        ]
        for path in each {
            var conditions = all
            conditions[keyPath: path] = false
            #expect(!policy.installs(conditions))
        }
        #expect(!policy.installs(RemoteSystemShortcuts.Conditions()))
    }

    nonisolated enum Key {
        static let space: UInt16 = 0x31
        static let tab: UInt16 = 0x30
        static let grave: UInt16 = 0x32
        static let escape: UInt16 = 0x35
        static let up: UInt16 = 0x7E
        static let down: UInt16 = 0x7D
        static let left: UInt16 = 0x7B
        static let right: UInt16 = 0x7C
        static let three: UInt16 = 0x14
        static let four: UInt16 = 0x15
        static let five: UInt16 = 0x17
        static let q: UInt16 = 0x0C
        static let w: UInt16 = 0x0D
        static let h: UInt16 = 0x04
        static let m: UInt16 = 0x2E
        static let t: UInt16 = 0x11
        static let a: UInt16 = 0x00
        static let c: UInt16 = 0x08
        static let returnKey: UInt16 = 0x24
    }

    nonisolated struct Chord: Sendable, CustomTestStringConvertible {
        let key: UInt16
        let modifiers: NSEvent.ModifierFlags
        init(_ key: UInt16, _ modifiers: NSEvent.ModifierFlags) {
            self.key = key
            self.modifiers = modifiers
        }
        var testDescription: String { "key \(key) modifiers \(modifiers.rawValue)" }
    }

    nonisolated static let systemChords: [Chord] = [
        Chord(Key.space, .command), Chord(Key.space, [.command, .option]), Chord(Key.space, .control),
        Chord(Key.tab, .command), Chord(Key.tab, [.command, .shift]), Chord(Key.grave, .command),
        Chord(Key.up, .control), Chord(Key.down, .control), Chord(Key.left, .control), Chord(Key.right, .control),
        Chord(Key.three, [.command, .shift]), Chord(Key.four, [.command, .shift]), Chord(Key.five, [.command, .shift]),
        Chord(Key.q, [.control, .command]), Chord(Key.q, .command), Chord(Key.w, .command), Chord(Key.h, .command),
        Chord(Key.m, .command),
    ]

    nonisolated static let otherKeys: [Chord] = [
        // Ordinary typing and editing go through the capture view.
        Chord(Key.a, []), Chord(Key.a, .shift), Chord(Key.space, []), Chord(Key.tab, []), Chord(Key.returnKey, []),
        Chord(Key.up, []), Chord(Key.c, .command),
        // cmux's own chords outside the system list keep the existing rule.
        Chord(Key.t, .command), Chord(Key.t, [.command, .shift]),
    ]

    @Test(arguments: MacScreenSystemShortcutTapTests.systemChords)
    func takesSystemChords(chord: Chord) {
        #expect(policy.takes(keyCode: chord.key, modifiers: chord.modifiers))
    }

    @Test(arguments: MacScreenSystemShortcutTapTests.otherKeys)
    func passesEverythingElse(chord: Chord) {
        #expect(!policy.takes(keyCode: chord.key, modifiers: chord.modifiers))
    }

    @Test func neverTakesTheReleaseChord() {
        #expect(!policy.takes(keyCode: Key.escape, modifiers: [.control, .option]))
        // A release chord rebound onto a system chord still releases.
        var rebound = policy
        rebound.releaseChord = RemoteReleaseChord(keyCode: Key.up, modifiers: .control)
        #expect(!rebound.takes(keyCode: Key.up, modifiers: .control))
        #expect(rebound.takes(keyCode: Key.down, modifiers: .control))
    }

    @Test func aTakenChordSendsItsKeyAndItsUp() {
        var policy = policy
        var keyboard = RemoteKeyboardState()
        let space = RemoteHIDKeyMap().usage(forKeyCode: Key.space)
        #expect(space == 0x0007_002C)
        let down = policy.route(RemoteTapKey(keyCode: Key.space, modifiers: .command, down: true), keyboard: &keyboard)
        #expect(down == [.key(usage: 0x0007_002C, down: true)])
        // Auto-repeat is the host's job: taken, nothing sent.
        let again = policy.route(RemoteTapKey(keyCode: Key.space, modifiers: .command, down: true, isRepeat: true), keyboard: &keyboard)
        #expect(again == [])
        // The up is taken even after Command went up first.
        let up = policy.route(RemoteTapKey(keyCode: Key.space, modifiers: [], down: false), keyboard: &keyboard)
        #expect(up == [.key(usage: 0x0007_002C, down: false)])
        #expect(keyboard.heldKeys.isEmpty)
        // A key the tap did not take is not its business, down or up.
        #expect(policy.route(RemoteTapKey(keyCode: Key.a, modifiers: [], down: true), keyboard: &keyboard) == nil)
        #expect(policy.route(RemoteTapKey(keyCode: Key.a, modifiers: [], down: false), keyboard: &keyboard) == nil)
        #expect(policy.route(RemoteTapKey(keyCode: Key.escape, modifiers: [.control, .option], down: true), keyboard: &keyboard) == nil)
    }

    @Test func readsKeysFromTapEvents() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: Key.tab, keyDown: true))
        event.flags = [.maskCommand, .maskShift]
        let key = try #require(RemoteTapKey(type: .keyDown, event: event))
        #expect(key == RemoteTapKey(keyCode: Key.tab, modifiers: [.command, .shift], down: true))
        let up = try #require(CGEvent(keyboardEventSource: nil, virtualKey: Key.five, keyDown: false))
        up.flags = [.maskCommand, .maskShift]
        #expect(RemoteTapKey(type: .keyUp, event: up) == RemoteTapKey(keyCode: Key.five, modifiers: [.command, .shift], down: false))
        var policy = policy
        var keyboard = RemoteKeyboardState()
        #expect(policy.route(key, keyboard: &keyboard) == [.key(usage: 0x0007_002B, down: true)])
        let flags = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0x37, keyDown: true))
        #expect(RemoteTapKey(type: .flagsChanged, event: flags) == nil)
    }
}
