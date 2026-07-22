/// Resource limits applied before a catalog ZIP or XPI reaches WebKit.
public struct BrowserWebExtensionArchiveLimits: Equatable, Sendable {
    /// The production bounds for compressed and expanded catalog packages.
    public static let standard = BrowserWebExtensionArchiveLimits(
        maximumCompressedByteCount: 25 * 1024 * 1024,
        maximumExpandedByteCount: 256 * 1024 * 1024,
        maximumEntryCount: 10_000
    )

    public let maximumCompressedByteCount: Int
    public let maximumExpandedByteCount: Int
    public let maximumEntryCount: Int

    public init(
        maximumCompressedByteCount: Int,
        maximumExpandedByteCount: Int,
        maximumEntryCount: Int
    ) {
        precondition(maximumCompressedByteCount > 0)
        precondition(maximumExpandedByteCount > 0)
        precondition(maximumEntryCount > 0)
        self.maximumCompressedByteCount = maximumCompressedByteCount
        self.maximumExpandedByteCount = maximumExpandedByteCount
        self.maximumEntryCount = maximumEntryCount
    }
}

/// Controls whether a compressed WebExtension package may be imported.
public enum BrowserWebExtensionArchivePolicy: Equatable, Sendable {
    /// Reject compressed input whose expanded contents cannot be bounded by cmux.
    case reject

    /// Accept a catalog package only after its complete bytes and ZIP metadata
    /// satisfy the pinned digest and declared resource bounds.
    case verifiedCatalog(
        expectedSHA256: String,
        limits: BrowserWebExtensionArchiveLimits = .standard
    )
}
