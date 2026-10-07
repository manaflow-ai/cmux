#if DEBUG
import Foundation

/// Launch-time configuration for the iOS render-recovery stress harness.
public struct MobileRecoveryStressConfiguration: Equatable, Sendable {
    /// The cycle count used when the launch argument omits or cannot parse a value.
    public static let defaultCycles = 200

    /// Number of forced render-pipeline recovery cycles to run.
    public let cycles: Int

    /// Creates a configuration with a positive cycle count.
    public init(cycles: Int = Self.defaultCycles) {
        self.cycles = max(1, cycles)
    }

    /// Parses `--cmux-recovery-stress <N>` from process launch arguments.
    public static func parse(arguments: [String]) -> Self? {
        guard let flagIndex = arguments.firstIndex(of: "--cmux-recovery-stress") else {
            return nil
        }
        let valueIndex = arguments.index(after: flagIndex)
        guard valueIndex < arguments.endIndex,
              let parsed = Int(arguments[valueIndex]),
              parsed > 0 else {
            return Self()
        }
        return Self(cycles: parsed)
    }
}
#endif
