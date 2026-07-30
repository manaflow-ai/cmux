/// A cached read-only reactive value derived from other signals or memos.
@MainActor
public final class SignalMemo<Value: Equatable>: SignalDependency, SignalObserver {
    let schedulingPriority = 0

    private let graph: SignalGraph
    private let compute: @MainActor () -> Value
    private var dependencies: [ObjectIdentifier: any SignalDependency] = [:]
    private var observers: [ObjectIdentifier: WeakSignalObserver] = [:]
    private var isPrimed = false
    private lazy var cachedValue: Value = graph.withObserver(self, compute)

    init(graph: SignalGraph, compute: @escaping @MainActor () -> Value) {
        self.graph = graph
        self.compute = compute
    }

    /// Reads the cached value and records this memo as a dependency.
    ///
    /// - Returns: The most recently computed value.
    public func get() -> Value {
        graph.track(self)
        return cachedValue
    }

    func prime() {
        isPrimed = true
        _ = cachedValue
    }

    func observe(_ dependency: any SignalDependency) {
        let identifier = ObjectIdentifier(dependency)
        guard dependencies[identifier] == nil else { return }
        dependencies[identifier] = dependency
        dependency.addObserver(self)
    }

    func run() {
        guard isPrimed else { return }
        let previousValue = cachedValue
        detachDependencies()
        let newValue = graph.withObserver(self, compute)
        guard newValue != previousValue else { return }
        cachedValue = newValue
        graph.schedule(liveObservers())
    }

    func addObserver(_ observer: any SignalObserver) {
        observers[ObjectIdentifier(observer)] = WeakSignalObserver(observer)
    }

    func removeObserver(_ observer: any SignalObserver) {
        observers.removeValue(forKey: ObjectIdentifier(observer))
    }

    private func detachDependencies() {
        for dependency in dependencies.values {
            dependency.removeObserver(self)
        }
        dependencies.removeAll(keepingCapacity: true)
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

    deinit {
        MainActor.assumeIsolated {
            detachDependencies()
        }
    }
}
