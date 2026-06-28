public import Foundation
public import CoreGraphics

/// Pure leaf helpers lifted out of the app-target `TextBoxInputTextView`
/// (`Sources/TextBoxInput.swift`): the invisible text-marker characters the
/// text box uses for inline attachments and pending uploads, plus the
/// Foundation/`String`/`NSRange`-only transforms that operate on selection
/// ranges, composed-character boundaries, attachment-cleanup keys, and
/// baseline-offset attribute values.
///
/// These carry no live `NSTextView` state. The live view stays app-side and
/// owns `textStorage`/`layoutManager`/`typingAttributes`; it forwards into
/// these helpers, passing its current backing string or length in as values.
///
/// The two marker characters are instance state so callers can configure them
/// at construction; the default initializer reproduces the exact characters the
/// god file hardcoded (`U+FFFC` object replacement, `U+200B` zero-width space).
/// The selection/position/attribute transforms take no marker state and are
/// `static`.
public struct TextBoxInputTextMarkers: Sendable, Equatable {
    /// The object-replacement character (`U+FFFC`) that backs an inline
    /// attachment cell in the text storage.
    public let attachmentReplacementCharacter: String

    /// The zero-width space (`U+200B`) that holds the caret position for a
    /// pending attachment upload before the real attachment is inserted.
    public let pendingAttachmentUploadPlaceholderCharacter: String

    /// Creates a marker set. The defaults reproduce the characters the text box
    /// has always used; tests may override them.
    public init(
        attachmentReplacementCharacter: String = "\u{FFFC}",
        pendingAttachmentUploadPlaceholderCharacter: String = "\u{200B}"
    ) {
        self.attachmentReplacementCharacter = attachmentReplacementCharacter
        self.pendingAttachmentUploadPlaceholderCharacter = pendingAttachmentUploadPlaceholderCharacter
    }

    /// Returns `text` with both marker characters removed, leaving only the
    /// user-visible text content.
    public func stringByStrippingNonTextMarkers(from text: String) -> String {
        text
            .replacingOccurrences(of: attachmentReplacementCharacter, with: "")
            .replacingOccurrences(of: pendingAttachmentUploadPlaceholderCharacter, with: "")
    }

    /// The stable per-file key used to track an attachment's local file for
    /// automatic cleanup: the standardized filesystem path of `fileURL`.
    public static func attachmentCleanupKey(for fileURL: URL) -> String {
        fileURL.standardizedFileURL.path
    }

    /// Whether `range` is a usable selection range within a backing string of
    /// the given `length` (non-`NSNotFound`, non-negative, and not past the end).
    public static func isValidSelectedRange(_ range: NSRange, length: Int) -> Bool {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0 else {
            return false
        }
        return NSMaxRange(range) <= length
    }

    /// Maps `selectedRange` through an edit that replaced `replacedRange` with
    /// `insertedLength` characters, within a backing string of the given
    /// `length`. Returns where the caret/selection should land after the edit.
    public static func adjustedSelectionRange(
        _ selectedRange: NSRange,
        replacing replacedRange: NSRange,
        insertedLength: Int,
        length: Int
    ) -> NSRange {
        guard isValidSelectedRange(selectedRange, length: length) else {
            return NSRange(location: NSMaxRange(replacedRange) + insertedLength, length: 0)
        }

        let delta = insertedLength - replacedRange.length
        if selectedRange.location > replacedRange.location {
            return NSRange(
                location: max(0, selectedRange.location + delta),
                length: selectedRange.length
            )
        }
        if NSIntersectionRange(selectedRange, replacedRange).length > 0 {
            return NSRange(location: replacedRange.location + insertedLength, length: 0)
        }
        return selectedRange
    }

    /// Coerces a `.baselineOffset` attribute value (which arrives as `Any?` from
    /// the text storage) to a `CGFloat`, defaulting to `0` when absent.
    public static func baselineOffsetValue(_ value: Any?) -> CGFloat {
        if let value = value as? CGFloat {
            return value
        }
        if let number = value as? NSNumber {
            return CGFloat(truncating: number)
        }
        return 0
    }

    /// The composed-character boundary at or before `location` in `string`,
    /// clamped to the string's bounds.
    public static func composedCharacterLocationBefore(_ location: Int, in string: String) -> Int {
        let nsText = string as NSString
        let clampedLocation = min(max(location, 0), nsText.length)
        guard clampedLocation > 0 else { return clampedLocation }
        return nsText.rangeOfComposedCharacterSequence(at: clampedLocation - 1).location
    }

    /// The composed-character boundary at or after `location` in `string`,
    /// clamped to the string's bounds.
    public static func composedCharacterLocationAfter(_ location: Int, in string: String) -> Int {
        let nsText = string as NSString
        let clampedLocation = min(max(location, 0), nsText.length)
        guard clampedLocation < nsText.length else { return clampedLocation }
        return NSMaxRange(nsText.rangeOfComposedCharacterSequence(at: clampedLocation))
    }
}
