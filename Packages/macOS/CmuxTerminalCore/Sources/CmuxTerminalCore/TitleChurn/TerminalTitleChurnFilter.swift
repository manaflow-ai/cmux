import Foundation

/// Collapses frame-by-frame spinner churn in terminal titles so an animated
/// title — e.g. an agent cycling `⠋ Working…`, `⠙ Working…`, `⠹ Working…`
/// through Braille glyphs on every animation frame — maps to one stable
/// string before it reaches the title-update ingress.
///
/// The ingress already rejects duplicate updates synchronously, but spinner
/// frames differ on every frame, so without this collapse the dedup never
/// fires and every frame pays an `AsyncStream` yield plus a global-executor
/// task enqueue on the main thread.
///
/// Scoped to Braille on purpose: unlike `|`, `/`, `-`, `*`, `▶`, `●`, …,
/// Braille patterns never legitimately *lead* a human-readable terminal
/// title, so stripping them cannot corrupt a real one. Stateless: callers
/// rely on their existing last-value dedup to drop the now-identical frames.
public enum TerminalTitleChurnFilter {
    /// Returns the stable title to publish for `rawTitle`, or `nil` when the
    /// frame is only a spinner glyph (no label survives the collapse) and
    /// should be dropped rather than blanking a previously shown label.
    public static func stableTitle(for rawTitle: String) -> String? {
        let stable = collapseTerminalTitleSpinnerFrames(rawTitle)
        if stable.isEmpty,
           !rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        return stable
    }
}

/// Strips a leading run of Braille spinner glyphs and the whitespace that
/// separates them from their label, returning the label untouched. A title
/// with no leading spinner is returned exactly as given — plain OSC titles
/// keep any intentional padding; only spinner frames are rewritten.
private func collapseTerminalTitleSpinnerFrames(_ rawTitle: String) -> String {
    var cursor = Substring(rawTitle)
    // A spinner frame may carry leading whitespace before the glyph; peek past
    // it to detect the spinner without disturbing non-spinner titles.
    while let character = cursor.first, character.isWhitespace {
        cursor = cursor.dropFirst()
    }
    guard let first = cursor.first, terminalTitleCharacterIsBrailleSpinnerGlyph(first) else {
        return rawTitle
    }
    // Strip the spinner-glyph run and the whitespace separating it from the
    // label; the label itself (including any trailing content) is kept.
    while let character = cursor.first, terminalTitleCharacterIsBrailleSpinnerGlyph(character) {
        cursor = cursor.dropFirst()
    }
    while let character = cursor.first, character.isWhitespace {
        cursor = cursor.dropFirst()
    }
    return String(cursor)
}

/// A spinner frame is a single Braille Pattern code point (U+2800…U+28FF).
/// Multi-scalar graphemes (emoji, combining sequences) are never spinner
/// glyphs.
private func terminalTitleCharacterIsBrailleSpinnerGlyph(_ character: Character) -> Bool {
    guard character.unicodeScalars.count == 1,
          let scalar = character.unicodeScalars.first else {
        return false
    }
    return (0x2800...0x28FF).contains(scalar.value)
}
