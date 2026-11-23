// cmux: text checking reads the words around a range of a long paragraph, not the paragraph. Not a vendored file.
//
// AppKit's `NSTextCheckingController` (automatic correction, text replacement, quote and dash substitution,
// candidates; continuous spell checking is `DeferredSpellChecker`, off the key) asks the field for an annotated copy
// of the text around a range four or five times a key (`annotatedSubstringForProposedRange:actualRange:`, the
// public `NSTextCheckingClient` protocol). NSTextView answers with the whole paragraph and merges its
// temporary-attribute runs over all of it (`temporaryAttributesAtCharacterIndex:longestEffectiveRange:inRange:`): at
// a 3,000-character one-paragraph draft those copies were about a fifth of each key's main-thread work (cmux21
// `sample`, 300 keys; a1250, 2026-11-21). The protocol lets a client cut a paragraph that exceeds a maximum length;
// the field answers a long one with the words around the range, built as AppKit builds its copy: the characters,
// with the TextKit 1 layout manager's temporary attributes (the spelling marks and the controller's annotations).
import AppKit

/// NSTextView's own `annotatedSubstringForProposedRange:actualRange:`, for the cases the field leaves to it.
private typealias AnnotatedCopy = @convention(c) (AnyObject, Selector, NSRange, UnsafeMutablePointer<NSRange>?) -> Unmanaged<NSAttributedString>?
private let annotatedCopySelector = #selector(NSTextCheckingClient.annotatedSubstring(forProposedRange:actualRange:))
private let appKitAnnotatedCopy = unsafeBitCast(class_getMethodImplementation(NSTextView.self, annotatedCopySelector), to: AnnotatedCopy.self)

/// The span of a long paragraph that text checking reads around a range.
struct FieldCheckingSpan {
    /// A paragraph longer than this (UTF-16 units) is read around the range only.
    let longParagraph: Int
    /// How far the span reaches on each side of the range, before it widens to whole words.
    let radius: Int
    /// The furthest the span widens to reach a word boundary.
    let wordSlack: Int

    init(longParagraph: Int = 1024, radius: Int = 128, wordSlack: Int = 64) {
        self.longParagraph = longParagraph
        self.radius = radius
        self.wordSlack = wordSlack
    }

    /// The span text checking reads for `proposed` in `text`, or nil when NSTextView's answer stands: a proposal of
    /// the whole document (`NSNotFound`), one outside the text, or one in a paragraph no longer than `longParagraph`.
    func range(proposed: NSRange, in text: NSString) -> NSRange? {
        guard proposed.location != NSNotFound, proposed.location <= text.length else { return nil }
        let clamped = NSRange(location: proposed.location, length: min(proposed.length, text.length - proposed.location))
        let paragraph = text.paragraphRange(for: clamped)
        guard paragraph.length > longParagraph else { return nil }
        let lo = max(paragraph.location, clamped.location - radius)
        let hi = min(NSMaxRange(paragraph), NSMaxRange(clamped) + radius)
        let start = widen(lo, by: -1, in: text, limit: paragraph.location)
        let end = widen(hi, by: 1, in: text, limit: NSMaxRange(paragraph))
        return NSRange(location: start, length: end - start)
    }

    /// `index` moved in `step` direction to the nearest white space, at most `wordSlack` units and never past `limit`.
    private func widen(_ index: Int, by step: Int, in text: NSString, limit: Int) -> Int {
        var i = index
        for _ in 0..<wordSlack {
            if i == limit { return i }
            let unit = step < 0 ? text.character(at: i - 1) : text.character(at: i)
            if let scalar = Unicode.Scalar(unit), CharacterSet.whitespacesAndNewlines.contains(scalar) { return i }
            i += step
        }
        return i
    }
}

extension FieldTextView {
    /// Text checking's annotated copy (``FieldCheckingSpan``): a long paragraph's span around `range`, else
    /// NSTextView's answer.
    @objc(annotatedSubstringForProposedRange:actualRange:)
    func checkingCopy(forProposedRange range: NSRange, actualRange: UnsafeMutablePointer<NSRange>?) -> NSAttributedString? {
        let text = string as NSString
        guard textLayoutManager == nil, let layout = layoutManager,
              let span = FieldCheckingSpan().range(proposed: range, in: text) else {
            return appKitAnnotatedCopy(self, annotatedCopySelector, range, actualRange)?.takeUnretainedValue()
        }
        let copy = NSMutableAttributedString(string: text.substring(with: span))
        var at = span.location
        while at < NSMaxRange(span) {
            var run = NSRange(location: NSNotFound, length: 0)
            let attributes = layout.temporaryAttributes(atCharacterIndex: at, longestEffectiveRange: &run, in: span)
            guard run.length > 0 else { break }
            if !attributes.isEmpty { copy.addAttributes(attributes, range: NSRange(location: run.location - span.location, length: run.length)) }
            at = NSMaxRange(run)
        }
        actualRange?.pointee = span
        return copy
    }
}
