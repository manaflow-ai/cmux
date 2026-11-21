import AppKit

/// The composer field's line geometry through TextKit 1 (`ComposeTextView` makes its field with
/// `usingTextLayoutManager: false`).
///
/// TextKit 2 lays out and draws an edited paragraph whole: each key at the end of one long
/// paragraph typeset and drew all of it again (cmux21, macOS 27, offscreen NSTextView, a key's
/// insert, layout and display, p50: 0.59 ms at 250 characters, 2.10 ms at 3,000, 2.82 ms at 6,000;
/// scripts/cmux-next/textkit-paragraph-key-bench.swift). TextKit 1 lays out from the edited line and
/// draws only the dirty lines: 0.33, 0.34 and 0.45 ms. These helpers answer what the field asked
/// TextKit 2 for (the caret's line, an attachment's box); a view with a text layout manager gets
/// nil from each, and none of them touches `layoutManager` on such a view (that would switch it to
/// TextKit 1).
extension NSTextView {
    /// The caret's line at UTF-16 offset `index`, in text container coordinates: its `minX` is the
    /// caret's x, its `minY` and `height` the line fragment's (TextKit 2's `.standard` segment at
    /// an empty range). `upstream`: at a soft wrap, the end of the line above.
    func textKit1CaretSegment(at index: Int, upstream: Bool) -> CGRect? {
        guard textLayoutManager == nil, let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return nil }
        let length = storage.length
        let at = min(max(0, index), length)
        let units = storage.string as NSString
        let previousIsBreak = at > 0 && units.character(at: at - 1) == 0x0A
        // Contiguous layout (the default): laid out up to the caret, from the first invalid line.
        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(length, at + 1)))
        if length == 0 || (at == length && previousIsBreak) {
            lm.ensureLayout(for: tc)
            let extra = lm.extraLineFragmentRect
            return CGRect(x: extra.minX, y: extra.minY, width: 0, height: extra.height)
        }
        let atEnd = at == length || (upstream && at > 0 && !previousIsBreak)
        let character = atEnd ? at - 1 : at
        let glyph = lm.glyphIndexForCharacter(at: character)
        let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
        // The line's own insertion point for AT: right for right-to-left text, where a glyph's
        // origin is the caret's place after it, not before it.
        if let x = Self.insertionPoint(lm, line: character, at: at) {
            return CGRect(x: line.minX + x, y: line.minY, width: 0, height: line.height)
        }
        let x = atEnd
            ? lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).maxX
            : line.minX + lm.location(forGlyphAt: glyph).x
        return CGRect(x: x, y: line.minY, width: 0, height: line.height)
    }

    /// The x of the caret at AT, from its line's start, on the line holding character LINE (TextKit
    /// 1's insertion points in logical order, the primary place at a direction change); nil when the
    /// line has no point for AT.
    private static func insertionPoint(_ lm: NSLayoutManager, line: Int, at: Int) -> CGFloat? {
        let count = lm.getLineFragmentInsertionPoints(forCharacterAt: line, alternatePositions: false, inDisplayOrder: false,
                                                      positions: nil, characterIndexes: nil)
        guard count > 0 else { return nil }
        var positions = [CGFloat](repeating: 0, count: count)
        var indexes = [Int](repeating: 0, count: count)
        _ = lm.getLineFragmentInsertionPoints(forCharacterAt: line, alternatePositions: false, inDisplayOrder: false,
                                              positions: &positions, characterIndexes: &indexes)
        return zip(indexes, positions).reversed().first { $0.0 == at }?.1
    }

    /// The box of the characters in `range`, in text container coordinates (TextKit 1), or nil.
    func textKit1Rect(for range: NSRange) -> CGRect? {
        guard textLayoutManager == nil, let lm = layoutManager, let tc = textContainer, range.length > 0 else { return nil }
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return lm.boundingRect(forGlyphRange: glyphs, in: tc)
    }

    /// Lays out the whole text (TextKit 1): after a new container width, so the document's height
    /// and the caret's line are the new ones. A view with a text layout manager is left alone.
    func textKit1LayOutAll() {
        guard textLayoutManager == nil, let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
    }
}
