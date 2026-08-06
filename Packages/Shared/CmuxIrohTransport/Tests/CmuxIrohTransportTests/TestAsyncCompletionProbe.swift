actor TestAsyncCompletionProbe {
    private var completeValue = false

    func complete() {
        completeValue = true
    }

    func isComplete() -> Bool {
        completeValue
    }
}
