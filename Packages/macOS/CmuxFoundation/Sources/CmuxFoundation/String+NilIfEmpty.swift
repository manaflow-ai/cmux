/// Returns `nil` for an empty string and the string itself otherwise, so callers can
/// collapse empty-or-missing text to a single optional at the use site.
extension String {
    /// `nil` when the string is empty, otherwise `self`.
    public var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
