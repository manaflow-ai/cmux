import AppKit
import Bonsplit

/// The per-window owner of overlay refresh admission and AppKit updates.
/// All input, layout and glass-root events pass through the same value gate.
@MainActor
final class TmuxWorkspacePaneOverlayCoordinator {
    private weak var window: NSWindow?
    private var lastSnapshot: TmuxWorkspacePaneOverlayRefreshSnapshot?
    private var geometryRefreshPending = false

    /// Refreshes from current model and AppKit values, rebuilding only when
    /// those values differ from the last admitted snapshot.
    @discardableResult
    func refresh(
        builder: TmuxWorkspacePaneOverlayStateBuilder,
        in newWindow: NSWindow? = nil,
        liveLayoutSnapshot: LayoutSnapshot? = nil
    ) -> Bool {
        if let newWindow {
            if let previousWindow = window, previousWindow !== newWindow {
                WindowTmuxWorkspacePaneOverlayController.controller(
                    for: previousWindow,
                    createIfNeeded: false
                )?.update(state: nil)
                lastSnapshot = nil
            }
            window = newWindow
        }
        guard let window else { return false }
        let inputs = builder.inputs
        let controller = WindowTmuxWorkspacePaneOverlayController.controller(
            for: window, createIfNeeded: inputs.isVisible
        )
        let reference = controller?.coordinateReferenceView ?? window.contentView
        let windowID = ObjectIdentifier(window)
        let referenceID = reference.map(ObjectIdentifier.init)
        let effectiveLayout = inputs.isVisible
            ? Self.normalizedLayoutSnapshot(
                WorkspaceContentView.effectiveTmuxLayoutSnapshot(
                    cachedSnapshot: builder.tabManager.selectedWorkspace?.tmuxLayoutSnapshot,
                    liveSnapshot: liveLayoutSnapshot
                        ?? builder.tabManager.selectedWorkspace?.bonsplitController.layoutSnapshot()
                )
            )
            : nil
        if let previous = lastSnapshot,
           previous.inputs == inputs,
           previous.window == windowID,
           previous.referenceView == referenceID,
           previous.referenceBounds == reference?.bounds,
           previous.effectiveLayout == effectiveLayout {
            // No model, live layout, or coordinate-space input changed, so
            // the exact panel conversions from the last admitted snapshot
            // remain valid. In particular, repeated geometry/focus
            // notifications do not pay the AppKit conversion cost before the
            // equality gate below.
            return false
        }
        var exactRects: [UUID: CGRect] = [:]
        if inputs.isVisible, let reference, let workspace = builder.tabManager.selectedWorkspace {
            for id in inputs.panelIdentities.keys {
                guard let panel = workspace.panels[id] else { continue }
                exactRects[id] = ContentView.tmuxWorkspacePaneExactRect(for: panel, in: reference)
            }
        }
        let snapshot = TmuxWorkspacePaneOverlayRefreshSnapshot(
            inputs: inputs,
            window: windowID,
            referenceView: referenceID,
            referenceBounds: reference?.bounds,
            exactRects: exactRects,
            effectiveLayout: effectiveLayout
        )
        return update(snapshot: snapshot) {
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

    private static func normalizedLayoutSnapshot(_ snapshot: LayoutSnapshot?) -> LayoutSnapshot? {
        snapshot.map {
            LayoutSnapshot(
                containerFrame: $0.containerFrame,
                panes: $0.panes,
                focusedPaneId: $0.focusedPaneId,
                timestamp: 0
            )
        }
    }
}
