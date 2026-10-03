import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// The Cmd-J leader at the key router (`ChordTracker`, `KeyRouter.canArm`):
/// Cmd-J arms it, the next key runs a leader chord, and Escape or any key
/// without a binding dismisses it without reaching the focused view.
@MainActor
struct LeaderChordRoutingTests {
    static let cmdJ = ShortcutChordRoutingTests.key(38, "j", .command)
    static let j = ShortcutChordRoutingTests.key(38, "j")
    static let escape = ShortcutChordRoutingTests.key(53, "\u{1B}")
    static let q = ShortcutChordRoutingTests.q

    static func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        registry.bind("terminal.scrollToSelection") {}
        return registry
    }

    static func step(_ chords: inout ChordTracker, _ event: NSEvent, _ registry: ActionRegistry, window: NSObject,
                     focus: FocusState.Resolved? = nil, canArm: Bool = true) -> ChordTracker.Step {
        chords.step(event, window: ObjectIdentifier(window), registry: registry, focus: focus) { canArm }
    }

    /// Cmd-J as a held key repeats it.
    static let cmdJRepeat = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                                             context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: true,
                                             keyCode: 38)!

    @Test func commandJThenJScrollsToTheSelection() {
        let registry = Self.registry(), window = NSObject()
        var chords = ChordTracker()
        #expect(Self.step(&chords, Self.cmdJ, registry, window: window) == .armed)
        #expect(chords.leaderPrefix == LeaderLayer.prefix)
        #expect(Self.step(&chords, Self.j, registry, window: window) == .run("terminal.scrollToSelection", argument: nil))
        #expect(!chords.isPending)
        #expect(chords.leaderPrefix == nil)
    }

    @Test func escapeOrAKeyWithoutABindingDismisses() {
        let registry = Self.registry(), window = NSObject()
        var chords = ChordTracker()
        _ = Self.step(&chords, Self.cmdJ, registry, window: window)
        #expect(Self.step(&chords, Self.escape, registry, window: window) == .dismissed)
        #expect(!chords.isPending)
        _ = Self.step(&chords, Self.cmdJ, registry, window: window)
        #expect(Self.step(&chords, Self.q, registry, window: window) == .dismissed)
        #expect(Self.step(&chords, Self.j, registry, window: window) == .pass, "a lone J types")
    }

    /// Cmd-J twice closes the overlay it opened.
    @Test func commandJAgainDismisses() {
        let registry = Self.registry(), window = NSObject()
        var chords = ChordTracker()
        _ = Self.step(&chords, Self.cmdJ, registry, window: window)
        #expect(Self.step(&chords, Self.cmdJ, registry, window: window) == .dismissed)
        #expect(!chords.isPending)
    }

    /// The overlay shows what Cmd-J offers even when nothing under it can
    /// run in this focus; the key after it then only dismisses.
    @Test func theLeaderArmsWhenNothingUnderItCanRunYet() {
        let registry = ActionRegistry.standard(), window = NSObject()
        var chords = ChordTracker()
        #expect(Self.step(&chords, Self.cmdJ, registry, window: window) == .armed)
        #expect(Self.step(&chords, Self.j, registry, window: window) == .dismissed)
    }

    /// Holding Cmd-J does not flicker the overlay: repeats keep the leader
    /// armed, and a repeat never arms it.
    @Test func holdingCommandJKeepsTheLeaderArmed() {
        let registry = Self.registry(), window = NSObject()
        var chords = ChordTracker()
        #expect(Self.step(&chords, Self.cmdJRepeat, registry, window: window) == .pass)
        #expect(!chords.isPending)
        #expect(Self.step(&chords, Self.cmdJ, registry, window: window) == .armed)
        #expect(Self.step(&chords, Self.cmdJRepeat, registry, window: window) == .armed)
        #expect(Self.step(&chords, Self.cmdJRepeat, registry, window: window) == .armed)
        #expect(chords.leaderPrefix == LeaderLayer.prefix)
        #expect(Self.step(&chords, Self.j, registry, window: window) == .run("terminal.scrollToSelection", argument: nil))
    }

    /// A click or Cmd-Tab moves focus while Cmd-J waits: the leader ends and
    /// the next key reaches the newly focused view. A settle on the focus it
    /// armed in keeps it.
    @Test func aFocusChangeEndsTheLeader() {
        let registry = Self.registry(), window = NSObject()
        var chords = ChordTracker()
        let terminal = KeyInterceptionTests.terminal.resolved, page = KeyInterceptionTests.page.resolved
        #expect(Self.step(&chords, Self.cmdJ, registry, window: window, focus: terminal) == .armed)
        let sameFocus = chords.focusDidChange(to: terminal, in: ObjectIdentifier(window))
        #expect(!sameFocus)
        let otherWindow = chords.focusDidChange(to: page, in: ObjectIdentifier(NSObject()))
        #expect(!otherWindow, "another window's focus")
        #expect(chords.isPending)
        let moved = chords.focusDidChange(to: page, in: ObjectIdentifier(window))
        #expect(moved)
        #expect(!chords.isPending)
        #expect(Self.step(&chords, Self.j, registry, window: window, focus: page) == .pass, "J types in the page")
    }

    /// `"toggleSidebar": "cmd+j"` in cmux.json: Cmd-J runs it, the leader
    /// does not arm.
    @Test func aUsersOwnCommandJDoesNotArmTheLeader() {
        let registry = Self.registry(), window = NSObject()
        registry.bind("toggleSidebar") {}
        registry.setShortcutOverride(LeaderLayer.prefix, for: "toggleSidebar")
        var chords = ChordTracker()
        #expect(Self.step(&chords, Self.cmdJ, registry, window: window) == .pass)
        #expect(registry.resolveShortcut(for: Self.cmdJ)?.id == "toggleSidebar")
    }

    /// Unbinding every leader chord in cmux.json gives Cmd-J back to the
    /// focused view (a Ghostty keybind of the user's).
    @Test func unbindingEveryLeaderChordFreesCommandJ() {
        let registry = Self.registry(), window = NSObject()
        for (id, _) in LeaderLayer.defaultChords { registry.setShortcutOverride(nil, for: id) }
        var chords = ChordTracker()
        #expect(Self.step(&chords, Self.cmdJ, registry, window: window) == .pass)
    }

    /// IME composition, text fields and browser focus mode keep Cmd-J; a
    /// terminal or a page arms it.
    @Test func markedTextOrATextFieldKeepsCommandJ() {
        #expect(KeyRouter.canArm(focus: KeyInterceptionTests.terminal, hasMarkedText: false))
        #expect(KeyRouter.canArm(focus: KeyInterceptionTests.page, hasMarkedText: false))
        #expect(!KeyRouter.canArm(focus: KeyInterceptionTests.terminal, hasMarkedText: true))
        #expect(!KeyRouter.canArm(focus: KeyInterceptionTests.omnibar, hasMarkedText: false))
        #expect(!KeyRouter.canArm(focus: KeyInterceptionTests.find, hasMarkedText: false))
        #expect(!KeyRouter.canArm(focus: KeyInterceptionTests.focusMode, hasMarkedText: false))

        let registry = Self.registry(), window = NSObject()
        var chords = ChordTracker()
        #expect(Self.step(&chords, Self.cmdJ, registry, window: window, canArm: false) == .pass)
        #expect(!chords.isPending)
    }

    /// A Ctrl-B chord (tmux preset) is not the leader: no overlay, and the
    /// key after it still reaches the view when it completes nothing.
    @Test func otherChordsKeepTheirMismatch() {
        let registry = ShortcutChordRoutingTests.registry(), window = NSObject()
        var chords = ChordTracker()
        #expect(Self.step(&chords, ShortcutChordRoutingTests.ctrlB, registry, window: window) == .armed)
        #expect(chords.leaderPrefix == nil)
        #expect(Self.step(&chords, Self.escape, registry, window: window) == .mismatch)
    }
}
