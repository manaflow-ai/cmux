import Foundation

struct SimulatorDeviceStateGate: Equatable, Sendable {
    private(set) var hasReportedUnavailable = false

    mutating func observe(state: String) -> SimulatorDeviceStateTransition? {
        if state.caseInsensitiveCompare("Booted") == .orderedSame {
            hasReportedUnavailable = false
            return nil
        }
        guard !hasReportedUnavailable else { return nil }
        hasReportedUnavailable = true
        return .becameUnavailable(state: state)
    }

    mutating func reset() {
        hasReportedUnavailable = false
    }
}
