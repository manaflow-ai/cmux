enum SimulatorCameraCleanupResult: Equatable, Sendable {
    case completed
    case failed(SimulatorFailure)
}
