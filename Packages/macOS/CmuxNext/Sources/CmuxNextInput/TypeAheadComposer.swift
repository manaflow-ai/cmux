public import AppKit

/// The text a key types into a page's type-ahead queue (KeyRouter+TypeAhead), decided the way the
/// selected input source decides it, because the queue is filled before any input method sees
/// the key (input-principles.md 4: text is queued only after the input source ran).
///
/// A keyboard layout's text is its own translation of the key (`UCKeyTranslate`) with the dead-key
/// state of the keys before it: a dead key (´ on US International, ^ on AZERTY, Option-E) types
/// nothing and is held here as state, and the next key types the composed character (é, ê).
/// An input method (Kotoeri, Pinyin, Korean, Telex) composes in its own engine, which only a live
/// text input client reaches: such a key is never queued as its raw characters (romaji).
public struct TypeAheadComposer {
    /// What one key does to the queue.
    public enum Outcome: Equatable, Sendable {
        /// Append this text.
        case text(String)
        /// A dead key: nothing yet; the next key composes with it.
        case deadKey
        /// The key is not text the router can compose: an input method is selected. Not queued.
        case notComposable
    }

    /// Translates a key on the selected keyboard layout with a dead-key state (in: before the key,
    /// out: after it); nil when the selected source is an input method, not a keyboard layout.
    public typealias Translate = (_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, _ deadKeyState: inout UInt32) -> String?

    public private(set) var deadKeyState: UInt32 = 0

    public init() {}

    /// The outcome of a key typed while the queue takes keys.
    public mutating func compose(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, translate: Translate) -> Outcome {
        var state = deadKeyState
        guard let typed = translate(keyCode, modifiers, &state) else {
            deadKeyState = 0
            return .notComposable
        }
        deadKeyState = state
        if typed.isEmpty { return state != 0 ? .deadKey : .text("") }
        return .text(typed)
    }

    /// The queue ended (a chord, a focus move, the text went to the page): no key composes with a
    /// dead key typed before it.
    public mutating func reset() {
        deadKeyState = 0
    }
}
