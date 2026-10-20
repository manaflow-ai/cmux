import Foundation

protocol SimulatorWorkerSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}
