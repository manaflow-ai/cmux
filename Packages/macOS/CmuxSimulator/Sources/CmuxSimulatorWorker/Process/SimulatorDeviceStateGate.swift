import Foundation

struct SimulatorDeviceStateGate: Equatable, Sendable {
    enum Transition: Equatable, Sendable {
        case becameUnavailable(state: String)
    }

    private(set) var hasReportedUnavailable = false

    mutating func observe(state: String) -> Transition? {
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
