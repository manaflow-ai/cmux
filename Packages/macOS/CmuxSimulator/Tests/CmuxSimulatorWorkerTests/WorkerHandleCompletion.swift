actor WorkerHandleCompletion {
    private(set) var result: Bool?

    func finish(_ result: Bool) {
        self.result = result
    }
}
