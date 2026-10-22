/// A prompt a REPL call puts in front of the user (the secure sign-in
/// sheet) and waits on: it ends once, with the user's answer, at its
/// timeout, or when the call or its session ends; `onEnd` then takes the
/// prompt down.
@MainActor
public final class BrowserReplPendingPrompt<Answer: Sendable> {
    private var continuation: CheckedContinuation<Answer, Never>?
    private var answer: Answer?
    private let onEnd: @MainActor () -> Void

    /// - Parameter onEnd: takes the prompt down; called once, when it ends.
    public init(onEnd: @escaping @MainActor () -> Void) {
        self.onEnd = onEnd
    }

    /// Whether the prompt has ended.
    public var isEnded: Bool { answer != nil }

    /// Waits for the prompt's answer: the user's (``finish(_:)``),
    /// `expired` after `timeout` on `clock`, or `cancelled` as soon as the
    /// waiting task is cancelled (at once when it already is). Either way
    /// the prompt is taken down.
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
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if answer == nil, Task.isCancelled { finish(cancelled) }
                if let answer {
                    continuation.resume(returning: answer)
                    return
                }
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(cancelled) }
        }
    }

    /// Ends the prompt with `answer`; later calls do nothing.
    public func finish(_ answer: Answer) {
        guard self.answer == nil else { return }
        self.answer = answer
        onEnd()
        continuation?.resume(returning: answer)
        continuation = nil
    }
}
