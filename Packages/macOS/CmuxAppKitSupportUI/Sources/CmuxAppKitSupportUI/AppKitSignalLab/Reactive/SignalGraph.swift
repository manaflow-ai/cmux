/// Owns synchronous dependency tracking and batched propagation for signals.
///
/// `SignalGraph` follows Solid's fine-grained model: reading a signal inside an
/// effect or memo records the dependency automatically, and writing a distinct
/// value schedules only the observers that read it. All access is main-actor
/// isolated so AppKit controls can be updated directly without locks.
@MainActor
public final class SignalGraph {
    private weak var activeObserver: (any SignalObserver)?
    private var pendingObservers: [ObjectIdentifier: any SignalObserver] = [:]
    private var batchDepth = 0
    private var isFlushing = false

    /// Creates an empty signal graph.
    public init() {}

    /// Creates a writable signal with an initial value.
    ///
    /// - Parameter initialValue: The signal's value before its first write.
    /// - Returns: A signal owned by this graph.
    public func createSignal<Value: Equatable>(_ initialValue: Value) -> Signal<Value> {
        Signal(graph: self, initialValue: initialValue)
    }

    /// Creates a cached read-only value whose dependencies are tracked automatically.
    ///
    /// The computation runs once immediately and then once per dependency change,
    /// with batched writes coalesced into one recomputation.
    ///
    /// - Parameter compute: A pure computation that reads signals or other memos.
    /// - Returns: A memo owned by this graph.
    public func createMemo<Value: Equatable>(_ compute: @escaping @MainActor () -> Value) -> SignalMemo<Value> {
        let memo = SignalMemo(graph: self, compute: compute)
        memo.prime()
        return memo
    }

    /// Creates and immediately runs a reactive side effect.
    ///
    /// Keep the returned token alive for as long as the effect should remain
    /// subscribed. Releasing or disposing it detaches every dependency.
    ///
    /// - Parameter body: The side effect. Reads made synchronously by this closure
    ///   become dependencies for its next run.
    /// - Returns: A disposable effect token.
    @discardableResult
    public func createEffect(
        _ body: @escaping @MainActor (SignalEffectContext) -> Void
    ) -> SignalEffect {
        let effect = SignalEffect(graph: self, body: body)
        effect.run()
        return effect
    }

    /// Coalesces all writes in `updates` before recomputing memos and effects.
    ///
    /// - Parameter updates: Synchronous signal mutations to perform as one batch.
    public func batch(_ updates: () -> Void) {
        batchDepth += 1
        updates()
        batchDepth -= 1
        if batchDepth == 0 {
            flush()
        }
    }

    func track(_ dependency: any SignalDependency) {
        activeObserver?.observe(dependency)
    }

    func withObserver<Value>(
        _ observer: any SignalObserver,
        _ body: @MainActor () -> Value
    ) -> Value {
        let previousObserver = activeObserver
        activeObserver = observer
        defer { activeObserver = previousObserver }
        return body()
    }

    func schedule(_ observers: [any SignalObserver]) {
        for observer in observers {
            pendingObservers[ObjectIdentifier(observer)] = observer
        }
        if batchDepth == 0 {
            flush()
        }
    }

    private func flush() {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        while !pendingObservers.isEmpty {
            guard let observer = pendingObservers.values.min(by: {
                $0.schedulingPriority < $1.schedulingPriority
            }) else { return }
            pendingObservers.removeValue(forKey: ObjectIdentifier(observer))
            observer.run()
        }
    }
}
