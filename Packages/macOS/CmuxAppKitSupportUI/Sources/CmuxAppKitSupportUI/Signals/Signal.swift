/// A writable fine-grained reactive value.
///
/// Call ``get()`` inside a ``SignalEffect`` or ``SignalMemo`` computation to
/// subscribe that observer. Equal writes are ignored.
@MainActor
public final class Signal<Value: Equatable>: SignalDependency {
    private let graph: SignalGraph
    private var value: Value
    private var observers: [ObjectIdentifier: WeakSignalObserver] = [:]

    init(graph: SignalGraph, initialValue: Value) {
        self.graph = graph
        self.value = initialValue
    }

    /// Reads the current value and records a dependency in the active tracking scope.
    ///
    /// - Returns: The current signal value.
    public func get() -> Value {
        graph.track(self)
        return value
    }

    /// Replaces the value and notifies subscribers when it changed.
    ///
    /// - Parameter newValue: The next signal value.
    public func set(_ newValue: Value) {
        guard newValue != value else { return }
        value = newValue
        graph.schedule(liveObservers())
    }

    /// Replaces the value using its previous value.
    ///
    /// - Parameter update: A pure transformation from the old value to the new value.
    public func update(_ update: (Value) -> Value) {
        set(update(value))
    }

    func addObserver(_ observer: any SignalObserver) {
        observers[ObjectIdentifier(observer)] = WeakSignalObserver(observer)
    }

    func removeObserver(_ observer: any SignalObserver) {
        observers.removeValue(forKey: ObjectIdentifier(observer))
    }

    private func liveObservers() -> [any SignalObserver] {
        var live: [any SignalObserver] = []
        var staleIdentifiers: [ObjectIdentifier] = []
        for (identifier, observer) in observers {
            if let value = observer.value {
                live.append(value)
            } else {
                staleIdentifiers.append(identifier)
            }
        }
        for identifier in staleIdentifiers {
            observers.removeValue(forKey: identifier)
        }
        return live
    }
}
