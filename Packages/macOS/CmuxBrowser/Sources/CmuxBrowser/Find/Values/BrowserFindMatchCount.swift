import Foundation

/// The match tally returned by a find-in-page script evaluation.
///
/// Find scripts evaluate to a JSON string of the shape `{"total":N,"current":M}`.
/// `BrowserFindMatchCount` is the parsed, validated form of that payload: `total` is
/// the number of highlighted matches in the document, and `current` is the zero-based
/// index of the currently selected match (only meaningful when `total > 0`).
public struct BrowserFindMatchCount: Sendable, Equatable {
    /// The number of matches highlighted in the document.
    public let total: UInt

    /// The zero-based index of the currently selected match, or `nil` when there are no matches.
    public let selected: UInt?

    /// Creates a match count.
    /// - Parameters:
    ///   - total: The number of highlighted matches.
    ///   - selected: The zero-based index of the current match, or `nil` when `total` is `0`.
    public init(total: UInt, selected: UInt?) {
        self.total = total
        self.selected = selected
    }

    /// Parses the JSON string a find script evaluates to into a validated match count.
    ///
    /// The payload must be a JSON object with non-negative integer `total` and `current`
    /// fields, mirroring `{"total":N,"current":M}`. The selected index is reported only when
    /// `total > 0`; otherwise `selected` is `nil`. Any malformed, negative, or non-string
    /// input returns `nil` so callers can leave existing UI state untouched.
    ///
    /// - Parameter result: The raw value an `evaluateJavaScript` call produced.
    /// - Returns: The parsed match count, or `nil` when the payload is not a valid result.
    public static func parse(_ result: Any?) -> BrowserFindMatchCount? {
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = json["total"] as? Int,
              let current = json["current"] as? Int,
              total >= 0, current >= 0 else {
            return nil
        }
        return BrowserFindMatchCount(
            total: UInt(total),
            selected: total > 0 ? UInt(current) : nil
        )
    }
}
