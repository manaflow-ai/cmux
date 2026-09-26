/// Owns the explicit lifecycle observation state for a process-backed restore binding.
public struct RestoredProcessDetectionObservation: Equatable, Sendable {
    private var isArmed: Bool

    /// Creates a cleared observation policy.
    public init() {
        isArmed = false
    }

    /// Arms observation until authoritative process or shell evidence arrives.
    public mutating func arm() {
        isArmed = true
    }

    /// Returns whether the restore binding remains protected from an empty scan.
    public func preserves() -> Bool {
        isArmed
    }

    /// Clears observation after authoritative process or shell evidence.
    public mutating func clear() {
        isArmed = false
    }
}
