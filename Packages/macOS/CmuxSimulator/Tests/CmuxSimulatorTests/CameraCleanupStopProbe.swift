actor CameraCleanupStopProbe {
    private(set) var didFinish = false
    private var waiter: CheckedContinuation<Void, Never>?

    func finish() {
        didFinish = true
        waiter?.resume()
        waiter = nil
    }

    func waitUntilFinished() async {
        guard !didFinish else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
