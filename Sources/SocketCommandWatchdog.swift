struct SocketCommandWatchdog {
    private let task: Task<Void, Never>?

    init(task: Task<Void, Never>?) {
        self.task = task
    }

    func cancel() {
        task?.cancel()
    }
}
