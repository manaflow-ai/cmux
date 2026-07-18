public import Foundation

/// A structural invariant violation in canonical backend topology.
public enum CanonicalTopologyError: Error, Equatable, Sendable {
    /// A stable UUID appears more than once across canonical entities.
    case duplicateIdentity(UUID)

    /// A numeric entity identifier appears more than once within its entity kind.
    case duplicateNumericID(UInt64)

    /// A structural reference is missing, mismatched, duplicated, or empty.
    case invalidReference(String)

    /// A split ratio is non-finite or outside the open interval from zero to one.
    case invalidSplitRatio(Float)

    /// Canonical topology exceeded a declared depth or entity-count budget.
    case budgetExceeded(String)
}
