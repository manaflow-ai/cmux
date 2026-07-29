import os
import SwiftUI

/// Owns the lifecycle of one settings-store change-stream subscription:
/// a single `Task` that forwards each element from an `AsyncStream<Value>`
/// into a caller-supplied sink, and cancels that task when the driver is
/// deallocated.
///
/// This is the single source of truth for "observe a setting" teardown. The
/// owning object (a SwiftUI `@State` for ``LiveSetting``, or an `@Observable`
/// value model such as ``DefaultsValueModel``) holds the driver; when the
/// owner deallocates, the driver's `deinit` cancels the task. That
/// cancellation propagates into the parked `for await`, finishing the stream
/// and firing its `onTermination`, which tears down the underlying
/// `NotificationCenter.notifications(named:)` sequence. Relying on `weak self`
/// inside the loop is **not** sufficient: the task is suspended at the `await`
/// and never re-evaluates `self` for an idle key, so the subscription would
/// leak (see https://github.com/manaflow-ai/cmux/issues/5302).
///
/// The driver is store-agnostic — it only needs an `AsyncStream<Value>` — so
/// the same path works for every key kind (UserDefaults, JSON, secret) and
/// for both `@State`-backed and `@Observable`-backed consumers.
final class SettingReadDriver<Value: Sendable>: Sendable {
    private struct State {
        var isActivated = false
        var task: Task<Void, Never>?
    }

    /// `DynamicProperty.update()` is a nonisolated SwiftUI callback. The lock
    /// makes the synchronous activation boundary safe no matter which executor
    /// invokes that callback; delivered values still cross to MainActor below.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Starts forwarding `makeStream()`'s elements into `sink`. Idempotent:
    /// the first call wins and later calls are no-ops, so the subscription is
    /// created once for the lifetime of the owning object.
    ///
    /// - Parameters:
    ///   - makeStream: Builds the store change stream. Called at most once.
    ///   - sink: Receives each value on the main actor. Capture the consumer
    ///     weakly here so the forwarding task does not retain it.
    func activate(
        _ makeStream: () -> AsyncStream<Value>,
        sink: @escaping @MainActor @Sendable (Value) -> Void
    ) {
        guard claimActivation() else { return }
        let stream = makeStream()
        let task = Task {
            for await value in stream {
                if Task.isCancelled { break }
                await sink(value)
            }
        }
        install(task)
    }

    /// Starts forwarding an asynchronously-created stream into `sink`.
    ///
    /// Use this when stream creation itself must cross an isolation boundary
    /// before the returned stream can be iterated.
    ///
    /// - Parameters:
    ///   - makeStream: Builds the store change stream. Called at most once.
    ///   - sink: Receives each value on the main actor. Capture the consumer
    ///     weakly here so the forwarding task does not retain it.
    func activateAsync(
        _ makeStream: @escaping @MainActor @Sendable () async -> AsyncStream<Value>,
        sink: @escaping @MainActor @Sendable (Value) -> Void
    ) {
        guard claimActivation() else { return }
        let task = Task {
            let stream = await makeStream()
            for await value in stream {
                if Task.isCancelled { break }
                await sink(value)
            }
        }
        install(task)
    }

    private func claimActivation() -> Bool {
        state.withLock { state in
            guard !state.isActivated else { return false }
            state.isActivated = true
            return true
        }
    }

    private func install(_ task: Task<Void, Never>) {
        state.withLock { $0.task = task }
    }

    deinit {
        state.withLock { $0.task }?.cancel()
    }
}
