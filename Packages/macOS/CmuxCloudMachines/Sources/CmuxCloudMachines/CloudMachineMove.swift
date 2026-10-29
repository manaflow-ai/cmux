/// A move within a machine's existing pin tier.
///
/// Relative destinations name immutable machine identities so a refresh cannot
/// reinterpret a saved row offset. Adjacent moves use the current visible peers.
public enum CloudMachineMove: Equatable, Sendable {
    /// Move before the previous visible machine in the same pin tier.
    case up
    /// Move after the next visible machine in the same pin tier.
    case down
    /// Move to the start of the existing pin tier.
    case top
    /// Move before the named machine without crossing pin tiers.
    case before(String)
    /// Move after the named machine without crossing pin tiers.
    case after(String)
}
