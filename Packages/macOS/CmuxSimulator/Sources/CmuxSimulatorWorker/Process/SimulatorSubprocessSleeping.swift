import Foundation

protocol SimulatorSubprocessSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}
