actor SimulatorScheduledActionProbe {
    private(set) var startCount = 0
    private(set) var finishCount = 0

    func started() { startCount += 1 }
    func finished() { finishCount += 1 }

    func waitUntilStarted() async {
        while startCount == 0 { await Task.yield() }
    }
}
