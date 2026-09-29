import AppKit

/// The per-window owner of overlay refresh admission and AppKit updates.
/// All input, layout and glass-root events pass through the same value gate.
@MainActor
final class TmuxWorkspacePaneOverlayCoordinator {
    private weak var window: NSWindow?
    private var lastSnapshot: TmuxWorkspacePaneOverlayRefreshSnapshot?
    private var geometryRefreshPending = false

    /// Refreshes from current model and AppKit values, rebuilding only when
    /// those values differ from the last admitted snapshot.
    func refresh(builder: TmuxWorkspacePaneOverlayStateBuilder, in newWindow: NSWindow? = nil) {
        if let newWindow { window = newWindow }
        guard let window else { return }
        let inputs = builder.inputs
        let controller = WindowTmuxWorkspacePaneOverlayController.controller(
            for: window, createIfNeeded: inputs.isVisible
        )
        let reference = controller?.coordinateReferenceView ?? window.contentView
        var exactRects: [UUID: CGRect] = [:]
        if inputs.isVisible, let reference, let workspace = builder.tabManager.selectedWorkspace {
            for id in inputs.panelIdentities.keys {
                guard let panel = workspace.panels[id] else { continue }
                exactRects[id] = ContentView.tmuxWorkspacePaneExactRect(for: panel, in: reference)
            }
        }
        let snapshot = TmuxWorkspacePaneOverlayRefreshSnapshot(
            inputs: inputs,
            window: ObjectIdentifier(window),
            referenceView: reference.map(ObjectIdentifier.init),
            referenceBounds: reference?.bounds,
            exactRects: exactRects
        )
        update(snapshot: snapshot) {
            controller?.update(state: builder.state(for: window))
        }
    }

    /// Coalesces divider-driven geometry notifications into one refresh per
    /// main-actor turn before layout and AppKit conversion work runs.
    func scheduleGeometryRefresh(builder: TmuxWorkspacePaneOverlayStateBuilder) {
        guard !geometryRefreshPending else { return }
        geometryRefreshPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            geometryRefreshPending = false
            refresh(builder: builder)
        }
    }

    /// Admits one rendering transaction for changed inputs. A notification
    /// and SwiftUI update carrying the same values render only once.
    @discardableResult
    func update(snapshot: TmuxWorkspacePaneOverlayRefreshSnapshot, render: () -> Void) -> Bool {
        guard snapshot != lastSnapshot else { return false }
        lastSnapshot = snapshot
        render()
        return true
    }

    /// Releases the previous presentation when its SwiftUI host disappears.
    func detach() {
        if let window {
            WindowTmuxWorkspacePaneOverlayController.controller(for: window, createIfNeeded: false)?
                .update(state: nil)
        }
        window = nil
        lastSnapshot = nil
    }
}
