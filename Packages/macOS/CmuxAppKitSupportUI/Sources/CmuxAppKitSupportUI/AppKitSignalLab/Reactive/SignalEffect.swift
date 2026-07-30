/// A disposable side effect that automatically follows the signals it reads.
@MainActor
public final class SignalEffect: SignalObserver {
    let schedulingPriority = 1

    private let graph: SignalGraph
    private let body: @MainActor (SignalEffectContext) -> Void
    private var dependencies: [ObjectIdentifier: any SignalDependency] = [:]
    private var cleanups: [@MainActor () -> Void] = []
    private var isDisposed = false

    init(
        graph: SignalGraph,
        body: @escaping @MainActor (SignalEffectContext) -> Void
    ) {
        self.graph = graph
        self.body = body
    }

    /// Stops future executions, detaches dependencies, and runs registered cleanup.
    public func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        runCleanups()
        detachDependencies()
    }

    func observe(_ dependency: any SignalDependency) {
        let identifier = ObjectIdentifier(dependency)
        guard dependencies[identifier] == nil else { return }
        dependencies[identifier] = dependency
        dependency.addObserver(self)
    }

    func run() {
        guard !isDisposed else { return }
        runCleanups()
        detachDependencies()
        let context = SignalEffectContext { [weak self] cleanup in
            self?.cleanups.append(cleanup)
        }
        graph.withObserver(self) {
            body(context)
        }
    }

    private func runCleanups() {
        let pendingCleanups = cleanups
        cleanups.removeAll(keepingCapacity: true)
        for cleanup in pendingCleanups {
            cleanup()
        }
    }

    private func detachDependencies() {
        for dependency in dependencies.values {
            dependency.removeObserver(self)
        }
        dependencies.removeAll(keepingCapacity: true)
    }

    deinit {
        MainActor.assumeIsolated {
            runCleanups()
            detachDependencies()
        }
    }
}
