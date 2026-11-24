// cmux: right-to-left paragraphs in the TextKit 1 field. Not a vendored file.
import AppKit

/// Gives each paragraph of the composer field's text the writing direction of its first strong
/// letter (Unicode's rule P2; none: left to right), as the field's text storage delegate.
///
/// TextKit 2 did this itself: a Hebrew or Arabic paragraph started at the field's right edge. TextKit 1
/// lays out a paragraph whose style says `.natural` from the left edge (its natural alignment
/// follows the app's language, not the text), so a right-to-left draft sat at the left with its caret
/// off (HomeComposerTextKit1Tests). The style of a paragraph changes only when its direction does;
/// a key reads its paragraph's start and the letters up to the first strong one.
final class ComposeParagraphDirection: NSObject, NSTextStorageDelegate {
    func textStorage(_ storage: NSTextStorage, willProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters), storage.length > 0 else { return }
        let units = storage.string as NSString
        // The paragraph after the edit too: a deleted break joins it, a typed one starts it.
        let start = min(range.location, units.length)
        let probe = NSRange(location: start, length: min(range.length + 1, units.length - start))
        var paragraph = units.paragraphRange(for: probe)
        while paragraph.length > 0 {
            fix(storage, units, paragraph, edited: range)
            let next = NSMaxRange(paragraph)
            guard next < units.length, next < NSMaxRange(probe) else { break }
            paragraph = units.paragraphRange(for: NSRange(location: next, length: 0))
        }
    }

    /// Sets PARAGRAPH's style to its direction when its start or the edited text in it has another.
    private func fix(_ storage: NSTextStorage, _ units: NSString, _ paragraph: NSRange, edited: NSRange) {
        let wanted: NSWritingDirection = Self.isRightToLeft(units, paragraph) ? .rightToLeft : .natural
        func direction(at i: Int) -> NSWritingDirection {
            (storage.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle)?.baseWritingDirection ?? .natural
        }
        let editedInside = NSIntersectionRange(edited, paragraph)
        let last = editedInside.length > 0 ? NSMaxRange(editedInside) - 1 : paragraph.location
        guard direction(at: paragraph.location) != wanted || direction(at: last) != wanted else { return }
        storage.enumerateAttribute(.paragraphStyle, in: paragraph) { value, run, _ in
            guard let style = ((value as? NSParagraphStyle) ?? .default).mutableCopy() as? NSMutableParagraphStyle else { return }
            style.baseWritingDirection = wanted
            storage.addAttribute(.paragraphStyle, value: style, range: run)
        }
    }

    /// Whether the first strong letter of PARAGRAPH is right to left.
    static func isRightToLeft(_ units: NSString, _ paragraph: NSRange) -> Bool {
        var i = paragraph.location
        let end = NSMaxRange(paragraph)
        while i < end {
            let c = units.character(at: i)
            if UTF16.isLeadSurrogate(c), i + 1 < end, UTF16.isTrailSurrogate(units.character(at: i + 1)) {
                let scalar = UTF16.decode(c, units.character(at: i + 1))
                if let strong = strongDirection(scalar) { return strong }
                i += 2
                continue
            }
            if let scalar = Unicode.Scalar(c), let strong = strongDirection(scalar.value) { return strong }
            i += 1
        }
        return false
    }

    /// True for a right-to-left letter, false for a left-to-right one, nil for a character with no
    /// strong direction (a space, a digit, punctuation, an emoji, a mark).
    private static func strongDirection(_ value: UInt32) -> Bool? {
        switch value {
        case 0x0660...0x0669, 0x06F0...0x06F9: return nil  // Arabic-Indic digits
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
            guard let scalar = Unicode.Scalar(value), scalar.properties.isAlphabetic,
                  scalar.properties.generalCategory != .nonspacingMark else { return nil }
            return true
        default:
            guard let scalar = Unicode.Scalar(value), scalar.properties.isAlphabetic,
                  scalar.properties.generalCategory != .nonspacingMark else { return nil }
            return false
        }
    }
}

private extension UTF16 {
    /// The scalar value of a surrogate pair (the caller checks both halves; wrapping math never traps).
    static func decode(_ lead: UInt16, _ trail: UInt16) -> UInt32 {
        0x10000 &+ ((UInt32(truncatingIfNeeded: lead) &- 0xD800) << 10) &+ (UInt32(truncatingIfNeeded: trail) &- 0xDC00)
    }
}
