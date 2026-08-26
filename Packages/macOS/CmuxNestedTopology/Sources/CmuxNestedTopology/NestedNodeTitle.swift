/// A display title paired with explicit overwrite authority.
public struct NestedNodeTitle: Codable, Equatable, Sendable {
    /// Untrusted provider or user display value.
    public let value: String

    /// Source that controls whether later writers may replace the title.
    public let authority: NestedTitleAuthority

    /// Creates a title and authority pair.
    ///
    /// - Parameters:
    ///   - value: Display value, validated at snapshot boundaries.
    ///   - authority: Provenance and overwrite authority.
    public init(value: String, authority: NestedTitleAuthority) {
        self.value = value
        self.authority = authority
    }

    /// Applies a provenance-validated provider title while preserving local locks.
    func replacingFromProvider(with candidate: NestedNodeTitle?) -> NestedNodeTitle? {
        guard let candidate else {
            return authority.canBeClearedByProvider ? nil : self
        }
        guard candidate.authority.precedence >= authority.precedence else {
            return self
        }
        return candidate
    }

    /// Applies a trusted host/user lock without allowing an authority downgrade.
    func replacing(withLocalLock lock: NestedNodeTitle) -> NestedNodeTitle {
        lock.authority.precedence >= authority.precedence ? lock : self
    }
}
