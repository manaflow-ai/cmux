/// One-shot continuation guard shared by the surface executor callback and a
/// global timeout.
///
/// Actor isolation owns the optional continuation, so whichever path wins swaps
/// it to nil before resuming and the checked continuation is resumed at most once.
actor CopyableTextContinuationBox {
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: String?) {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: value)
    }
}
