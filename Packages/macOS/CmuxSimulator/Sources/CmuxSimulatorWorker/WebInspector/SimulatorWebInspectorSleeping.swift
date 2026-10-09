import Foundation

protocol SimulatorWebInspectorSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}
