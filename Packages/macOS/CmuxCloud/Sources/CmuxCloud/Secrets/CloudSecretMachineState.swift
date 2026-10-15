import Foundation

/// How one name on one machine compares with the vault.
public enum CloudSecretMachineState: String, Sendable {
    /// Delivered with the fingerprint the vault holds now.
    case current
    /// Delivered, but the vault's value has changed since.
    case stale
    /// In the machine's effective set, but not delivered (or not on the machine).
    case missing
    /// Delivered (or on the machine) but no longer in any scope that applies to it.
    case extra
}
