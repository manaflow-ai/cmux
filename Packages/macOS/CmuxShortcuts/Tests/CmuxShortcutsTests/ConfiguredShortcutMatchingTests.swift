import Testing
import CmuxSettings
@testable import CmuxShortcuts

@Suite("Configured shortcut chord-aware matching")
struct ConfiguredShortcutMatchingTests {
    private let cmd1 = ShortcutStroke(key: "1", command: true)
    private let cmd2 = ShortcutStroke(key: "2", command: true)
    private let cmdK = ShortcutStroke(key: "k", command: true)

    @Test("Unbound shortcut never matches")
    func unboundNeverMatches() {
        let unbound = StoredShortcut(first: ShortcutStroke(key: ""))
        #expect(unbound.matchesConfigured(activeChordPrefix: nil) { _ in true } == false)
    }

    @Test("Single-stroke shortcut matches its first stroke with no active prefix")
    func singleStrokeMatchesFirst() {
        let shortcut = StoredShortcut(first: cmd1)
        #expect(shortcut.matchesConfigured(activeChordPrefix: nil) { $0 == self.cmd1 })
        #expect(shortcut.matchesConfigured(activeChordPrefix: nil) { $0 == self.cmd2 } == false)
    }

    @Test("Chorded shortcut never matches a lone keystroke with no active prefix")
    func chordedRejectsLoneKeystroke() {
        let chord = StoredShortcut(first: cmd1, second: cmdK)
        #expect(chord.matchesConfigured(activeChordPrefix: nil) { _ in true } == false)
    }

    @Test("Active prefix matches the second stroke only when the first stroke equals the prefix")
    func activePrefixMatchesSecondStroke() {
        let chord = StoredShortcut(first: cmd1, second: cmdK)
        // Prefix equals the chord's first stroke -> matches on the second stroke.
        #expect(chord.matchesConfigured(activeChordPrefix: cmd1) { $0 == self.cmdK })
        #expect(chord.matchesConfigured(activeChordPrefix: cmd1) { $0 == self.cmd2 } == false)
        // Prefix differs from the chord's first stroke -> never matches.
        #expect(chord.matchesConfigured(activeChordPrefix: cmd2) { _ in true } == false)
    }

    @Test("Active prefix rejects a single-stroke shortcut (no second stroke)")
    func activePrefixRejectsSingleStroke() {
        let single = StoredShortcut(first: cmd1)
        #expect(single.matchesConfigured(activeChordPrefix: cmd1) { _ in true } == false)
    }

    @Test("Numbered digit: unbound shortcut resolves to nil")
    func numberedUnboundIsNil() {
        let unbound = StoredShortcut(first: ShortcutStroke(key: ""))
        #expect(unbound.numberedConfiguredDigit(activeChordPrefix: nil) { _ in 5 } == nil)
    }

    @Test("Numbered digit: single-stroke shortcut resolves its first stroke")
    func numberedSingleStrokeResolvesFirst() {
        let shortcut = StoredShortcut(first: cmd1)
        #expect(shortcut.numberedConfiguredDigit(activeChordPrefix: nil) { $0 == self.cmd1 ? 1 : nil } == 1)
    }

    @Test("Numbered digit: chorded shortcut resolves to nil with no active prefix")
    func numberedChordedNilWithoutPrefix() {
        let chord = StoredShortcut(first: cmd1, second: cmdK)
        #expect(chord.numberedConfiguredDigit(activeChordPrefix: nil) { _ in 9 } == nil)
    }

    @Test("Numbered digit: active prefix resolves the second stroke only when first equals prefix")
    func numberedActivePrefixResolvesSecond() {
        let chord = StoredShortcut(first: cmd1, second: cmdK)
        #expect(chord.numberedConfiguredDigit(activeChordPrefix: cmd1) { $0 == self.cmdK ? 7 : nil } == 7)
        #expect(chord.numberedConfiguredDigit(activeChordPrefix: cmd2) { _ in 7 } == nil)
    }

    @Test("KeyboardShortcutEvent: unbound shortcut never matches")
    func keyboardEventUnboundNeverMatches() {
        let unbound = StoredShortcut(first: ShortcutStroke(key: ""))
        #expect(unbound.matchesKeyboardShortcutEvent(
            usesNumberedDigitMatching: false,
            numberedDigit: { 1 },
            fullMatch: { true }
        ) == false)
    }

    @Test("KeyboardShortcutEvent: numbered action matches when a digit resolves")
    func keyboardEventNumberedUsesDigit() {
        let shortcut = StoredShortcut(first: cmd1)
        #expect(shortcut.matchesKeyboardShortcutEvent(
            usesNumberedDigitMatching: true,
            numberedDigit: { 4 },
            fullMatch: { false }
        ))
        #expect(shortcut.matchesKeyboardShortcutEvent(
            usesNumberedDigitMatching: true,
            numberedDigit: { nil },
            fullMatch: { true }
        ) == false)
    }

    @Test("KeyboardShortcutEvent: chorded non-numbered shortcut never matches; single-stroke defers to fullMatch")
    func keyboardEventNonNumberedBranches() {
        let chord = StoredShortcut(first: cmd1, second: cmdK)
        #expect(chord.matchesKeyboardShortcutEvent(
            usesNumberedDigitMatching: false,
            numberedDigit: { 1 },
            fullMatch: { true }
        ) == false)
        let single = StoredShortcut(first: cmd1)
        #expect(single.matchesKeyboardShortcutEvent(
            usesNumberedDigitMatching: false,
            numberedDigit: { 1 },
            fullMatch: { true }
        ))
        #expect(single.matchesKeyboardShortcutEvent(
            usesNumberedDigitMatching: false,
            numberedDigit: { 1 },
            fullMatch: { false }
        ) == false)
    }

    @Test("firstStrokeNumberedDigit: resolves first stroke only for an unbound-free single-stroke shortcut")
    func firstStrokeNumberedDigitBranches() {
        let single = StoredShortcut(first: cmd1)
        #expect(single.firstStrokeNumberedDigit { $0 == self.cmd1 ? 1 : nil } == 1)
        let chord = StoredShortcut(first: cmd1, second: cmdK)
        #expect(chord.firstStrokeNumberedDigit { _ in 1 } == nil)
        let unbound = StoredShortcut(first: ShortcutStroke(key: ""))
        #expect(unbound.firstStrokeNumberedDigit { _ in 1 } == nil)
    }
}
