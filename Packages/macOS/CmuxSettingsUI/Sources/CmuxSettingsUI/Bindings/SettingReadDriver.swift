import Observation
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
@MainActor
final class SettingReadDriver<Value: Sendable> {
    private var task: Task<Void, Never>?

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
        sink: @escaping @MainActor (Value) -> Void
    ) {
        guard task == nil else { return }
        let stream = makeStream()
        task = Task { @MainActor in
            for await value in stream {
                if Task.isCancelled { break }
                sink(value)
            }
        }
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
        guard task == nil else { return }
        task = Task { @MainActor in
            let stream = await makeStream()
            for await value in stream {
                if Task.isCancelled { break }
                sink(value)
            }
        }
    }

    deinit { task?.cancel() }
}
