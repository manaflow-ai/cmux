/// Authority required for a conditional paired-Mac route write.
public enum MobilePairedMacRouteWriteCondition: Sendable, Equatable {
    /// Require an existing scoped row whose authenticated instance tag exactly
    /// matches the expected value. A missing row is never created.
    case matchingInstanceTag(String?)

    /// Allow a missing row or an existing row that has not acquired an
    /// authenticated instance tag. Any claimed row rejects the write.
    case unclaimed
}
