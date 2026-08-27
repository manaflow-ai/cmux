import Foundation

/// Produces privacy-safe handles that correlate related events within one app run.
///
/// Swift's `Hasher` is randomly seeded for each process. The same opaque model
/// identifier therefore maps to the same integer inside one exported report,
/// while a later launch produces a different value. This keeps workspace,
/// surface, panel, and computer operations debuggable without persisting their
/// raw identifiers or creating a cross-launch tracking key.
public struct DiagnosticCorrelation: Sendable {
    public init() {}

    /// Returns a process-local handle for a non-empty opaque identifier.
    public func handle(for rawValue: String?) -> UInt32? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        var hasher = Hasher()
        hasher.combine(rawValue)
        return UInt32(truncatingIfNeeded: hasher.finalize())
    }
}
