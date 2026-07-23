actor FeedbackComposerRequestRecorder {
    private var requests: [CapturedFeedbackRequest] = []
    private var continuations: [CheckedContinuation<CapturedFeedbackRequest, Never>] = []

    func record(_ request: CapturedFeedbackRequest) {
        if continuations.isEmpty {
            requests.append(request)
        } else {
            continuations.removeFirst().resume(returning: request)
        }
    }

    func nextRequest() async -> CapturedFeedbackRequest {
        if requests.isEmpty == false {
            return requests.removeFirst()
        }

        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func reset() {
        requests.removeAll()
    }
}
