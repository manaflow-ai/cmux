/// Keeps one overlay sync observer registered; removing it (or releasing
/// the observation) unregisters only that observer.
@MainActor
public final class LayoutOverlaySyncObservation {
    private weak var root: LayoutRootView?
    private let id: Int

    init(root: LayoutRootView, id: Int) {
        self.root = root
        self.id = id
    }

    /// Unregisters the observer now.
    public func cancel() {
        root?.overlaySyncObservers[id] = nil
        root = nil
    }

    isolated deinit {
        cancel()
    }
}

extension LayoutRootView {
    /// Calls `block` after every overlay sync: a layout pass or an animation
    /// frame moved panes (column scroll spring, divider drag). Never called
    /// while nothing moves. Any number of observers; each lives as long as
    /// its returned observation.
    public func observeOverlaySync(_ block: @escaping () -> Void) -> LayoutOverlaySyncObservation {
        nextOverlaySyncObserver += 1
        overlaySyncObservers[nextOverlaySyncObserver] = block
        return LayoutOverlaySyncObservation(root: self, id: nextOverlaySyncObserver)
    }

    func notifyOverlaySync() {
        for block in overlaySyncObservers.values { block() }
    }
}
