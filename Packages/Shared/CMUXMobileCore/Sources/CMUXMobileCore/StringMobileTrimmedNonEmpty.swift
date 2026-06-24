public import Foundation

extension String {
    /// The receiver trimmed of leading and trailing whitespace and newlines,
    /// or `nil` when nothing remains after trimming.
    ///
    /// Lifted byte-faithfully from the legacy `TerminalController.mobileNonEmpty(_:)`
    /// payload helper. Optionality lives at the call site: an optional source reads
    /// `raw?.mobileTrimmedNonEmpty`, which yields `nil` for both a `nil` source and
    /// a whitespace-only one, matching the legacy behavior exactly.
    public var mobileTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
