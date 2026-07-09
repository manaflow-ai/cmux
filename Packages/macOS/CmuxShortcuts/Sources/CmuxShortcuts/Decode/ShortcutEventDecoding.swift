public import AppKit

/// The read-only seam through which the app target decodes a keyboard
/// ``NSEvent`` into the values its configured-shortcut matching needs.
///
/// ## Why this seam exists
///
/// The configured-shortcut dispatch in the app target (the large
/// `handleCustomShortcut` switch and its numbered-digit matchers) must turn a
/// raw `NSEvent` into two things before it can compare against a stored
/// shortcut: the *layout character* a physical key produces under the current
/// input source (so a Dvorak or Korean layout still matches a Latin binding),
/// and the *normalized character* a printed glyph maps to (so a Shift symbol
/// like `!` resolves back to its base digit `1`). Both of these are pure
/// transforms with no dependency on the app's window, tab, or focus state, so
/// they belong in a package, not on the `AppDelegate` god object.
///
/// The dispatch stays app-side for now (it reaches live window/tab/browser
/// state that cannot cross a module boundary); it reaches this decode through a
/// single injected reference, so the per-keystroke hot path takes one property
/// access and no new allocation.
///
/// ## Layout-provider injection
///
/// `layoutCharacter(forKeyCode:modifierFlags:)` is backed by an injectable
/// closure so tests can substitute a deterministic layout instead of the
/// machine's live input source. The production conformer
/// (``ShortcutCoordinator``) defaults it to the Carbon-backed
/// `KeyboardLayout.character(forKeyCode:modifierFlags:)` at the composition
/// root.
@MainActor
public protocol ShortcutEventDecoding: AnyObject {
    /// The character the physical `keyCode` produces under the current keyboard
    /// layout for shortcut matching, or `nil` when no ASCII-capable layout can
    /// resolve it.
    ///
    /// Faithful relocation of the former `AppDelegate.shortcutLayoutCharacterProvider`
    /// stored closure: the app's `ShortcutStroke`/`StoredShortcut` matchers call
    /// this to get the layout-aware character they compare against a binding.
    func layoutCharacter(forKeyCode keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> String?

    /// Maps a printed shortcut character to the base key it should match against,
    /// undoing Shift-symbol production so `!`→`1`, `{`→`[`, `?`→`/`, and the
    /// always-on European-layout cases `+`→`=` / `_`→`-`.
    ///
    /// Faithful relocation of the former `AppDelegate.normalizedShortcutEventCharacter(_:applyShiftSymbolNormalization:eventKeyCode:)`.
    /// `applyShiftSymbolNormalization` gates the Shift-only symbol table; the
    /// `+`/`_` cases apply regardless because those glyphs only originate from a
    /// dedicated key on the layouts where they appear unshifted, and no shortcut
    /// is ever stored as `+`/`_`.
    func normalizedShortcutEventCharacter(
        _ eventCharacter: String,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> String

    /// The digit 1–9 a numbered shortcut event resolves to, or `nil` when the
    /// event is not a bound numbered key.
    ///
    /// Combines the printed-character path (normalized via
    /// ``normalizedShortcutEventCharacter(_:applyShiftSymbolNormalization:eventKeyCode:)``),
    /// the physical number-key keyCode fallback, and a layout-character fallback
    /// for non-ASCII input sources. `modifierFlags` must already be the event's
    /// flags (this method derives the device-independent subset itself), and
    /// `requireModifierFlags` is the bound stroke's modifier set the event must
    /// match. Faithful relocation of the former numbered-digit decode that lived
    /// across `AppDelegate.numberedShortcutDigit(event:stroke:)` and its helpers.
    func numberedShortcutDigit(
        eventKeyCode: UInt16,
        eventCharactersIgnoringModifiers: String?,
        eventModifierFlags: NSEvent.ModifierFlags,
        requireModifierFlags: NSEvent.ModifierFlags
    ) -> Int?
}
