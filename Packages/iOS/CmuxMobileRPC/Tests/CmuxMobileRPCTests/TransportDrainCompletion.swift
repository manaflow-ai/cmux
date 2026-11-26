actor TransportDrainCompletion {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
    }
}
