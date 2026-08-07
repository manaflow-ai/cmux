/// Identifies whether title authority came from provider input or trusted state.
enum NestedTitleAuthoritySource: Sendable {
    /// Untrusted provider snapshot or event input.
    case providerInput

    /// A snapshot previously published by trusted cmux code.
    case publishedSnapshot
}
