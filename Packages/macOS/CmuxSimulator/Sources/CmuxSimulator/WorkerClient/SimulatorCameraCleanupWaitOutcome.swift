enum SimulatorCameraCleanupWaitOutcome: Sendable {
    case completed(SimulatorCameraCleanupResult)
    case timedOut
    case cancelled
}
