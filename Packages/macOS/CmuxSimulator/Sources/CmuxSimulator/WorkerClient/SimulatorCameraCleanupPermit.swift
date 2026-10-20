actor SimulatorCameraCleanupPermit {
    private var isCancelled = false

    func allowsMutation() -> Bool {
        !isCancelled
    }

    func cancel() {
        isCancelled = true
    }
}
