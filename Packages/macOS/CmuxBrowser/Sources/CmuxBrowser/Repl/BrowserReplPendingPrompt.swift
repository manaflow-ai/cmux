/// A prompt a REPL call puts in front of the user (the secure sign-in
/// sheet) and waits on: it ends once, with the user's answer, at its
/// timeout, or when the call or its session ends; `onEnd` then takes the
/// prompt down.
@MainActor
public final class BrowserReplPendingPrompt<Answer: Sendable> {
    private var continuation: CheckedContinuation<Answer, Never>?
    private var ended = false
    private let onEnd: @MainActor () -> Void

    /// - Parameter onEnd: takes the prompt down; called once, when it ends.
    public init(onEnd: @escaping @MainActor () -> Void) {
        self.onEnd = onEnd
    }

    /// Whether the prompt has ended.
    public var isEnded: Bool { ended }

    /// Waits for the prompt's answer, `expired` after `timeout` on `clock`.
    /// Seam: today's wait.
    public func wait<C: Clock>(
        timeout: Duration,
        clock: C = ContinuousClock(),
        expired: Answer,
        cancelled: Answer
    ) async -> Answer where C.Duration == Duration {
        let timer = Task { @MainActor [weak self] in
            try? await clock.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finish(expired)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            if ended { return }
            self.continuation = continuation
        }
    }

    /// Ends the prompt with `answer`; later calls do nothing.
    public func finish(_ answer: Answer) {
        guard !ended else { return }
        ended = true
        onEnd()
        continuation?.resume(returning: answer)
        continuation = nil
    }
}
