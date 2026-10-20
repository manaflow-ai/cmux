/// The outcome of applying an equalize pass (mirrors the legacy
/// `SplitEqualizer.Result`).
public struct SplitEqualizeResult: Equatable, Sendable {
    /// Whether any split matched the orientation filter.
    public let foundSplit: Bool
    /// Whether every planned divider move (and split-id parse) succeeded.
    public let allSucceeded: Bool

    /// Whether the pass both found a split and fully applied.
    public var didFullyEqualize: Bool { foundSplit && allSucceeded }

    /// Creates a result.
    public init(foundSplit: Bool, allSucceeded: Bool) {
        self.foundSplit = foundSplit
        self.allSucceeded = allSucceeded
    }
}
