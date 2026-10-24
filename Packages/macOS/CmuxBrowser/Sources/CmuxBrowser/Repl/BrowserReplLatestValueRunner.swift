import Foundation

/// Applies submitted values one at a time on the main actor, keeping only
/// the newest one waiting: a value submitted while another is applied
/// replaces any value not applied yet, so a burst of updates costs at most
/// the one in progress and the last.
///
/// The REPL driver applies domain policies through it: each policy's
/// content rules compile in WebKit on the main actor, and an agent can set
/// policies far faster than WebKit compiles them.
public final class BrowserReplLatestValueRunner<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Value?
    private var running: Task<Void, Never>?
    private let apply: @MainActor @Sendable (Value) async -> Void

    public init(apply: @escaping @MainActor @Sendable (Value) async -> Void) {
        self.apply = apply
    }

    /// Applies `value` after the one in progress, if any, unless a newer
    /// value is submitted before then. Callable from any thread.
    public func submit(_ value: Value) {
        lock.withLock {
            pending = value
            guard running == nil else { return }
            running = Task { @MainActor [self] in await drain() }
        }
    }

    /// Returns once no value is applied or waiting.
    public func idle() async {
        while let task = lock.withLock({ running }) {
            await task.value
        }
    }

    @MainActor
    private func drain() async {
        while let value = takePending() {
            await apply(value)
        }
    }

    /// The waiting value, or nil (and the runner is idle) when none waits.
    private func takePending() -> Value? {
        lock.withLock {
            guard let value = pending else {
                running = nil
                return nil
            }
            pending = nil
            return value
        }
    }
}
