actor AttachmentCompletionProbe {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}
