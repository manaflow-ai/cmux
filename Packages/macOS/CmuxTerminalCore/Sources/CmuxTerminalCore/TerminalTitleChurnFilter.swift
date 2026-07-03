public import Foundation

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
///      A title with no leading spinner is returned exactly as given.
///   2. **Dedup** — a collapsed title equal to the one last dispatched *for the
///      same surface* is dropped, so a steady spinner emits a single post.
///
/// Isolation is `@MainActor`: `lastDispatchedTitle` is mutable per-surface state
/// touched from the Ghostty title callback (which may arrive off-main), so the
/// type enforces that the dedup runs on the main actor.
///
/// Scoped to Braille on purpose: most other spinner glyphs (`|`, `/`, `-`, `*`,
/// `▶`, `●`, …) can legitimately begin a real title, so stripping them would
/// corrupt it. Braille patterns never legitimately *lead* a human-readable
/// terminal title. Behavior is covered by `TerminalTitleChurnFilterTests`.
@MainActor
public struct TerminalTitleChurnFilter {
    private var lastSurfaceID: UUID?
    private var lastDispatchedTitle: String?

    /// Creates an empty title churn filter with no previously dispatched title.
    public init() {}

    /// Returns the stable title to post for `rawTitle` on `surfaceID`, or `nil`
    /// when this is a redundant spinner frame or duplicate that should not be
    /// posted at all.
    ///
    /// `surfaceID` is part of the dedup key so a view reused for a new surface
    /// always dispatches that surface's first title, even when its collapsed
    /// label matches the previous surface's last one.
    ///
    /// - Parameters:
    ///   - rawTitle: The title exactly as emitted by Ghostty.
    ///   - surfaceID: The terminal surface that emitted `rawTitle`.
    /// - Returns: The title to post, or `nil` when the frame should be dropped.
    public mutating func titleToDispatch(for rawTitle: String, surfaceID: UUID) -> String? {
        let stable = Self.collapseSpinnerFrames(rawTitle)
        // A frame that is *only* a spinner glyph (no label survives the
        // collapse) carries no title of its own; dropping it avoids blanking a
        // label a previous frame already showed.
        if stable.isEmpty,
           !rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        if surfaceID == lastSurfaceID, stable == lastDispatchedTitle {
            return nil
        }
        lastSurfaceID = surfaceID
        lastDispatchedTitle = stable
        return stable
    }

    /// Strips a leading run of Braille spinner glyphs and the whitespace that
    /// separates them from their label, returning the label untouched. A title
    /// with no leading spinner is returned **exactly** as given — plain OSC
    /// titles keep any intentional padding; only spinner frames are rewritten.
    /// Private: behavior is exercised through `titleToDispatch` in tests.
    private static func collapseSpinnerFrames(_ rawTitle: String) -> String {
        var cursor = Substring(rawTitle)
        // A spinner frame may carry leading whitespace before the glyph; peek
        // past it to detect the spinner without disturbing non-spinner titles.
        while let character = cursor.first, character.isWhitespace {
            cursor = cursor.dropFirst()
        }
        guard let first = cursor.first, isBrailleSpinnerGlyph(first) else {
            return rawTitle
        }
        // Strip the spinner-glyph run and the whitespace separating it from the
        // label; the label itself (including any trailing content) is kept.
        while let character = cursor.first, isBrailleSpinnerGlyph(character) {
            cursor = cursor.dropFirst()
        }
        while let character = cursor.first, character.isWhitespace {
            cursor = cursor.dropFirst()
        }
        return String(cursor)
    }

    /// A spinner frame is a single Braille Pattern code point. Multi-scalar
    /// graphemes (emoji, combining sequences) are never spinner glyphs.
    private static func isBrailleSpinnerGlyph(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return false
        }
        return (0x2800...0x28FF).contains(scalar.value)
    }
}
