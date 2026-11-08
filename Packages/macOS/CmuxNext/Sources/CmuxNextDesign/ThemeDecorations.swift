public import CmuxNextDesignTokens

/// The theme's personality decorations: named slots in the chrome that a look can fill with
/// something playful, the first step toward ricing (Leo 2026-11-05: "we're eventually gonna let
/// people rice it ... add some more, like, cute stuff"). Each slot holds at most one decoration,
/// by name; a slot with none draws exactly what it draws without decorations.
///
/// Pages get the filled slots with the theme (``WebTheme/decorations``) as
/// `data-cmux-decoration-<slot>="<name>"` on `<html>`, and draw the decoration themselves. An
/// empty set sends nothing, so a page's payload and markup are what they were before slots.
///
/// One slot and one decoration so far: the "cmux Updated!" card's doodle (``updateDoodle``, a
/// hand-drawn "you're on ...!" pointing at What's New, after the Yab browser's). Later fillers
/// (a theme of its own, Leo's "cat ears on the composer") add a slot here and fill it.
public nonisolated struct ThemeDecorations: Equatable, Sendable {
    /// A place in the chrome a decoration can fill.
    public enum Slot: String, CaseIterable, Sendable {
        /// The "cmux Updated!" card in the sidebar (UpdateSurfaces.tsx `UpdatedCard`).
        case updatedCard = "updated-card"
    }

    /// The decoration name in each filled slot.
    public let filled: [Slot: String]

    public init(_ filled: [Slot: String] = [:]) {
        self.filled = filled
    }

    /// The decorations the app draws now: the Debug toggles' (DEV and NIGHTLY builds; Release
    /// keeps every slot empty).
    public static var current: ThemeDecorations {
        ThemeDecorations(updateDoodle.value ? [.updatedCard: "doodle"] : [:])
    }

    /// `slot` to decoration name, as the page reads them (empty without decorations).
    public var payload: [String: String] {
        Dictionary(uniqueKeysWithValues: filled.map { ($0.key.rawValue, $0.value) })
    }

    /// The Updated card's doodle (off by default, an opt-in look until it is promoted): after an
    /// update the card draws a hand-drawn note, "you're on <version>!", a curved arrow to its
    /// What's New button with a loop around it, and "got it". Shown once per version, as the card
    /// is: got it and What's New each mark the version seen.
    public static let updateDoodle = Tunable<Bool>.toggle(
        "theme.decorations.updateDoodle", .shape, "Doodle on the Updated card",
        help: "After an update, the \"cmux Updated!\" card draws a hand-drawn note pointing at What's New, with \"got it\" to dismiss it. Applies to the next card that shows.",
        default: false, code: "ThemeDecorations.updateDoodle")

    public static var tunables: [TunableDescriptor] { [updateDoodle.descriptor] }
}
