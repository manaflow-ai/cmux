public import CmuxNextDesign
import Foundation

/// Keeps one overlay sync observer registered; removing it (or releasing
/// the observation) unregisters only that observer.
@MainActor
public final class LayoutOverlaySyncObservation {
    private weak var root: LayoutRootView?
    private let id: Int
    private let remove: @MainActor (LayoutRootView, Int) -> Void

    init(root: LayoutRootView, id: Int, remove: @escaping @MainActor (LayoutRootView, Int) -> Void = { $0.overlaySyncObservers[$1] = nil }) {
        self.root = root
        self.id = id
        self.remove = remove
    }

    /// Unregisters the observer now.
    public func cancel() {
        if let root { remove(root, id) }
        root = nil
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            cancel()
        }
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

    /// Calls `block` with true when a layout motion starts (a split, close, zoom, New Column, a
    /// released divider or a strip scroll springs) and with false after the frame it lands in:
    /// content that is expensive to move every frame (a Chromium page window) can tell motion
    /// frames from rest. During the motion, each frame's ``observeOverlaySync(_:)`` call carries
    /// ``panesMovedInLastOverlaySync``. Lives as long as the returned observation.
    public func observeLayoutMotion(_ block: @escaping (_ moving: Bool) -> Void) -> LayoutOverlaySyncObservation {
        nextOverlaySyncObserver += 1
        layoutMotionObservers[nextOverlaySyncObserver] = block
        return LayoutOverlaySyncObservation(root: self, id: nextOverlaySyncObserver, remove: { $0.layoutMotionObservers[$1] = nil })
    }
}

/// The floating panes' cards (`MainPaneChromeShadeView`): every displayed
/// pane of the shown screens, cut to what this view shows (a column
/// scrolled past its edge, a screen sliding in).
extension LayoutRootView: PaneCardSource {
    public var paneCardsInWindow: [PaneCard] {
        guard window != nil, !isHiddenOrHasHiddenAncestor, !isParkedOrHasParkedAncestor else { return [] }
        let visible = convert(bounds, to: nil)
        return screenViews.values.filter { !$0.isHidden && $0.alphaValue > 0.01 }.flatMap { screen in
            screen.displayedHosts.filter { !$0.isHidden && $0.alphaValue > 0.01 }.compactMap { host in
                let rect = host.cardInWindow.intersection(visible)
                return rect.isEmpty ? nil : PaneCard(rect: rect, radius: PaneChromeGeometry.cornerRadius(for: host.contentRect, style: context.style))
            }
        }
    }

    public func observePaneCards(_ block: @escaping () -> Void) -> AnyObject { observeOverlaySync(block) }
}
