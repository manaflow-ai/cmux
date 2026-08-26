/// Captures whether a possible HTML tag was valid, invalid, or unterminated.
enum HTMLFoundationCompatibilityTagScan: Sendable {
    case tag(HTMLFoundationCompatibilityTag)
    case invalidOpener
    case unterminated
}
