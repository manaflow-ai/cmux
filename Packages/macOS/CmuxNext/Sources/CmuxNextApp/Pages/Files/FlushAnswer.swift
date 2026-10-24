/// Resumes the pages' flush wait of one `FileQuitDocument` quit flush once: when every page
/// answered, or at the timeout.
final class FlushAnswer {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiting: Int
    var onFinish: (() -> Void)?
    init(_ continuation: CheckedContinuation<Void, Never>, waiting: Int) {
        self.continuation = continuation
        self.waiting = waiting
    }
    func answered() {
        waiting -= 1
        if waiting <= 0 { finish() }
    }
    func finish() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume()
        onFinish?()
        onFinish = nil
    }
}
