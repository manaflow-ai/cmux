import Foundation

struct SystemSudoBrokerClock: SudoBrokerClock {
    func now() async -> Date {
        .now
    }

    func sleep(until deadline: Date) async throws {
        let delay = deadline.timeIntervalSinceNow
        guard delay > 0 else { return }
        try await ContinuousClock().sleep(for: .seconds(delay))
    }
}
