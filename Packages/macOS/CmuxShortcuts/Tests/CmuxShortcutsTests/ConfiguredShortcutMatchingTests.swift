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
}
