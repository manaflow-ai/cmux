/// Describes one bounded HTML tag scan used by Foundation normalization.
struct HTMLFoundationCompatibilityTag: Sendable {
    let nameRange: Range<Int>
    let endIndex: Int
    let isClosing: Bool
    let selfClosingSlashIndex: Int?
}
