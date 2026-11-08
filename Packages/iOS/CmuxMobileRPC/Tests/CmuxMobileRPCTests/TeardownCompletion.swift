actor TeardownCompletion {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
    }
}
