actor CameraCleanupStopProbe {
    private(set) var didFinish = false

    func finish() {
        didFinish = true
    }
}
