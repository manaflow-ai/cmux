public import AppKit

extension LayoutRootView {
    /// Runs `work` now when no layout motion moves the layout `view` is in (or `view` is in none), else once when the
    /// motion lands: view-tree work that marks the whole window (a constraints pass) stays out of the motion's frames
    /// (RESIZE VIDEOS F1).
    public static func atRest(of view: NSView, _ work: @escaping @MainActor () -> Void) {
        guard let root = sequence(first: view, next: { $0.superview }).lazy.compactMap({ $0 as? LayoutRootView }).first,
              root.isInLayoutMotion else { return work() }
        var landing: LayoutOverlaySyncObservation?
        landing = root.observeLayoutMotion { moving in
            guard !moving else { return }
            landing?.cancel()
            landing = nil
            work()
        }
    }

    /// `view`, parked hidden in `host`, stops following its size: its autoresizing mask clears, when the layout is at
    /// rest. The mask's setter asks every ancestor for a constraints pass, a walk of the whole window in the next commit;
    /// a close parks the closing pane's terminal in its motion (RESIZE VIDEOS F1). Written only when it changes.
    public static func stopsFollowing(_ view: NSView, in host: NSView) {
        guard !view.autoresizingMask.isEmpty else { return }
        atRest(of: host) { [weak view, weak host] in
            if let view, view.isHidden, view.superview === host, !view.autoresizingMask.isEmpty { view.autoresizingMask = [] }
        }
    }
}
