import CmuxFoundation
import SwiftUI

/// Owns the lifecycle of one settings-store change-stream subscription:
/// a single forwarding operation that sends each element from an
/// `AsyncStream<Value>` into a caller-supplied sink and ends when the driver
/// is deallocated.
///
/// This is the single source of truth for "observe a setting" teardown. The
/// owning object (a SwiftUI `@State` for ``LiveSetting``, or an `@Observable`
/// value model such as ``DefaultsValueModel``) holds the driver; when the
/// owner deallocates, the driver's `deinit` finishes a lifetime signal. The
/// forwarding operation then cancels its parked `for await`, firing the
/// stream's `onTermination`, which tears down the underlying
/// `NotificationCenter.notifications(named:)` sequence. Relying on `weak self`
/// inside the loop is **not** sufficient: the task is suspended at the `await`
/// and never re-evaluates `self` for an idle key, so the subscription would
/// leak (see https://github.com/manaflow-ai/cmux/issues/5302).
///
/// The driver is store-agnostic — it only needs an `AsyncStream<Value>` — so
/// the same path works for every key kind (UserDefaults, JSON, secret) and
/// for both `@State`-backed and `@Observable`-backed consumers.
final class SettingReadDriver<Value: Sendable>: Sendable {
    /// `DynamicProperty.update()` is a nonisolated SwiftUI callback. The atomic
    /// claim keeps activation synchronous and safe no matter which executor
    /// invokes that callback.
    private let isActivated = AtomicBooleanGate(false)
    /// Finishing this bounded signal ends the forwarding operation without
    /// retaining the driver in its observation task.
    private let lifetime: AsyncStream<Void>
    private let lifetimeContinuation: AsyncStream<Void>.Continuation

    init() {
        (lifetime, lifetimeContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
    }

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
        guard isActivated.compareExchange(expected: false, desired: true) else { return }
        let stream = makeStream()
        start({ stream }, sink: sink)
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
        guard isActivated.compareExchange(expected: false, desired: true) else { return }
        start(makeStream, sink: sink)
    }

    private func start(
        _ makeStream: @escaping @Sendable () async -> AsyncStream<Value>,
        sink: @escaping @MainActor @Sendable (Value) -> Void
    ) {
        let lifetime = lifetime
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    let stream = await makeStream()
                    for await value in stream {
                        if Task.isCancelled { break }
                        await sink(value)
                    }
                }
                group.addTask {
                    for await _ in lifetime {}
                }
                await group.next()
                group.cancelAll()
            }
        }
    }

    deinit {
        lifetimeContinuation.finish()
    }
}
