import Foundation

/// Collapses frame-by-frame terminal-title churn at the source so an animated
/// spinner title — e.g. an agent cycling `⠋ Working…`, `⠙ Working…`, `⠹ Working…`
/// through Braille spinner glyphs on every animation frame — does not flood the
/// main thread with redundant `.ghosttyDidSetTitle` posts.
///
/// Each title post drives the workspace panel-title coalescer, the toolbar
/// command-text updater, and a sidebar re-render. A 10–30 fps spinner therefore
/// thrashes main-thread layout, which on some macOS versions surfaces as
/// repeated `NSHostingView is being laid out reentrantly while rendering its
/// SwiftUI content` faults and a wedged UI that leaves an agent stuck at
/// `Working…` (issues #6507, #4735; same family as #6291).
///
/// Both reductions are lossless for the *settled* title a user actually reads:
///   1. **Collapse** — a leading run of Unicode Braille Pattern glyphs
///      (`U+2800…U+28FF`) plus the whitespace separating them from their label
///      is stripped, so every animation frame maps to the same stable string.
///   2. **Dedup** — a collapsed title equal to the one last dispatched for this
///      surface is dropped, so a steady spinner emits a single post instead of
///      one per frame.
///
/// Scoped to Braille on purpose: most other spinner glyphs (`|`, `/`, `-`, `*`,
/// `▶`, `●`, …) can legitimately begin a real title, so stripping them would
/// corrupt it. Braille patterns never legitimately *lead* a human-readable
/// terminal title. See `TerminalTitleChurnFilterTests`.
struct TerminalTitleChurnFilter {
    private var lastDispatchedTitle: String?

    /// Returns the stable title to post for `rawTitle`, or `nil` when this is a
    /// redundant spinner frame / duplicate that should not be posted at all.
    /// Mutating; keep one filter per surface and call it on the main actor.
    mutating func titleToDispatch(for rawTitle: String) -> String? {
        let stable = Self.collapseSpinnerFrames(rawTitle)
        // A frame that is *only* a spinner glyph (no label survives the
        // collapse) carries no title of its own; dropping it avoids blanking a
        // label a previous frame already showed.
        if stable.isEmpty,
           !rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        guard stable != lastDispatchedTitle else { return nil }
        lastDispatchedTitle = stable
        return stable
    }

    /// Strips a leading run of Braille spinner glyphs and the whitespace that
    /// follows them, then trims. Pure and side-effect free; exposed for tests.
    static func collapseSpinnerFrames(_ rawTitle: String) -> String {
        // NOTE (commit 1 of the regression pair): no spinner collapse yet, so
        // `TerminalTitleChurnFilterTests` fails — proving the test catches the
        // churn. The real collapse lands in the following commit.
        return rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A spinner frame is a single Braille Pattern code point. Multi-scalar
    /// graphemes (emoji, combining sequences) are never spinner glyphs.
    static func isBrailleSpinnerGlyph(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return false
        }
        return (0x2800...0x28FF).contains(scalar.value)
    }
}
