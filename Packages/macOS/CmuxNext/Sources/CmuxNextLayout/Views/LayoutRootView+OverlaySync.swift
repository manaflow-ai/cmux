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
        // Live: in a window, not hidden and not parked (`setLive` keeps it at each transition, no walk here).
        guard isLive else { return [] }
        let visible = convert(bounds, to: nil)
        return screenViews.values.filter { !$0.isHidden && $0.alphaValue > 0.01 }.flatMap { screen in
            screen.displayedHosts.filter { !$0.isHidden && $0.alphaValue > 0.01 }.compactMap { host in
                // A pan on the strip's motion container, or a row's or area's, shows the card moved by its translation.
                let moved = screen.panTranslation(of: host)
                let card = host.cardInWindow.offsetBy(dx: moved.dx, dy: moved.dy)
                let rect = card.intersection(visible)
                return rect.isEmpty ? nil : PaneCard(rect: rect, radius: PaneChromeGeometry.cornerRadius(for: host.contentRect, style: context.style))
            }
        }
    }

    public func observePaneCards(_ block: @escaping () -> Void) -> AnyObject { observeOverlaySync(block) }
}

extension LayoutViewContext {
    /// The screens' two ways to move `root`'s overlay: once before this turn's frame commits, after whatever
    /// moved hosts (`setNeedsOverlaySync`), or now. Now is a render-server spring's start
    /// (`SplitMotion.placeAtRest`): its hosts are at rest, and the plane places every ring and dim there so
    /// each host's springs carry its chrome from that rest in one group (`PaneHostView.springToRest`); the
    /// springs then run with no sync until they land, and the sync this turn scheduled finds every ring placed.
    /// The plane's coordinates are the root's (`syncOverlay`), so a host's start converts there through the root.
    func wireOverlaySync(to root: LayoutRootView) {
        overlayNeedsSync = { [weak root] in root?.setNeedsOverlaySync() }
        overlaySyncNow = { [weak root] in
            guard let root else { return }
            root.overlayIsStale = true
            root.flushOverlaySync()
        }
        overlayPlaneRect = { [weak root] rect, view in root?.convert(rect, from: view) }
    }
}
