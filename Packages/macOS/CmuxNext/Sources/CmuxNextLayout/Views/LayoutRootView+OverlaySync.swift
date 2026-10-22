public import CmuxNextDesign
import Foundation

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
