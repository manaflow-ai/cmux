@testable import CmuxSimulator

actor CameraCleanupResultSequence {
    private var results: [SimulatorCameraCleanupResult]
    private(set) var attemptCount = 0

    init(_ results: [SimulatorCameraCleanupResult]) {
        self.results = results
    }

    func next() -> SimulatorCameraCleanupResult {
        attemptCount += 1
        guard !results.isEmpty else { return .completed }
        return results.removeFirst()
    }
}
