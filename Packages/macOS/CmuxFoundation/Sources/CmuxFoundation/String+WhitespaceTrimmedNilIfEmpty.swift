import Foundation

/// Whitespace-collapsing normalization shared by callers that treat a blank string
/// (after trimming) as "absent" and want a single optional at the use site, e.g.
/// a notification's reported working directory.
extension String {
    /// `self` trimmed of leading and trailing whitespace and newlines, or `nil`
    /// when nothing but whitespace remains.
    public var whitespaceTrimmedNilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
