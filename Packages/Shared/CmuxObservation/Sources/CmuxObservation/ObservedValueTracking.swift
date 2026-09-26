import Foundation
import Observation

/// Multicasts an `@Observable` value through one cancellable observation loop.
///
/// Each call to ``changes()`` receives the current value immediately and then
/// receives distinct values after tracked mutations. Subscriber churn only
/// changes the stream continuations; it never arms another registrar entry.
@MainActor
public final class ObservedValueTracking<Value: Equatable & Sendable>: Sendable {
    private var read: (@MainActor () -> Value)?
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    private var trackingArmed = false
    private var cancelled = false
    private var hasPublished = false
    private var lastPublished: Value?

    /// Creates a tracker around the tracked read closure.
    ///
    /// - Parameter read: A main-actor read that accesses every property whose
    ///   changes should wake subscribers.
    public init(read: @escaping @MainActor () -> Value) {
        self.read = read
    }

    /// Returns a replaying stream that shares this tracker's one observation loop.
    public func changes() -> AsyncStream<Value> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            guard !cancelled, let read else {
                continuation.finish()
                return
            }
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.removeContinuation(id)
                }
            }
            if let lastPublished {
                continuation.yield(lastPublished)
            } else {
                let value = read()
                hasPublished = true
                lastPublished = value
                continuation.yield(value)
            }
            armIfNeeded()
        }
    }

    /// Stops delivery and finishes every active stream.
    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        read = nil
        continuations.values.forEach { $0.finish() }
        continuations.removeAll()
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func armIfNeeded() {
        guard !cancelled, !trackingArmed, let read else { return }
        trackingArmed = true
        _ = withObservationTracking {
            read()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.cancelled else { return }
                self.trackingArmed = false
                guard let value = self.read?() else { return }
                self.publish(value)
                self.armIfNeeded()
            }
        }
    }

    private func publish(_ value: Value) {
        guard !hasPublished || lastPublished != value else { return }
        hasPublished = true
        lastPublished = value
        continuations.values.forEach { $0.yield(value) }
    }
}
