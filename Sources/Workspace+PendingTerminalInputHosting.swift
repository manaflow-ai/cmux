import AppKit
import CmuxTerminal
import CmuxWorkspaces
import Foundation

/// `Workspace` is the live host for its ``PendingTerminalInputCoordinator``. Each
/// member reproduces a read or side effect the legacy `sendInputWhenReady` body
/// performed inline against the panel registry, the `TerminalPanel` surface, and
/// `NotificationCenter`. The coordinator owns the per-panel registry and the
/// one-shot wait/timeout policy; this host supplies only the live AppKit state.
/// The coordinator is held by `Workspace` and references this host weakly, so
/// there is no retain cycle.
extension Workspace: PendingTerminalInputHosting {
    /// The package-opaque observation handle returned by
    /// ``observeTerminalSurfaceReady(forPanelId:onReady:)``. It owns the
    /// `NotificationCenter` token the legacy `WorkspacePendingTerminalInputObserver`
    /// box held; ``cancel()`` removes the observer and clears the token, idempotent
    /// like the legacy optional-guarded removal.
    private final class ReadyObservation: PendingTerminalInputObservation {
        var token: NSObjectProtocol?

        init(token: NSObjectProtocol?) {
            self.token = token
        }

        func cancel() {
            if let token {
                NotificationCenter.default.removeObserver(token)
                self.token = nil
            }
        }
    }

    func isTerminalSurfaceReady(forPanelId panelId: UUID) -> Bool {
        // Legacy fast-path `panel.surface.surface != nil`.
        guard let panel = panels[panelId] as? TerminalPanel else { return false }
        return panel.surface.surface != nil
    }

    func sendTerminalInput(_ text: String, toPanelId panelId: UUID) {
        // Legacy `panel.sendInput(text)`, re-resolving through the registry exactly
        // as the legacy ready callback's `self.panels[panelId] as? TerminalPanel` did.
        guard let panel = panels[panelId] as? TerminalPanel else { return }
        panel.sendInput(text)
    }

    func requestBackgroundSurfaceStart(forPanelId panelId: UUID) {
        // Legacy `panel.surface.requestBackgroundSurfaceStartIfNeeded()`.
        guard let panel = panels[panelId] as? TerminalPanel else { return }
        panel.surface.requestBackgroundSurfaceStartIfNeeded()
    }

    func observeTerminalSurfaceReady(
        forPanelId panelId: UUID,
        onReady: @escaping @MainActor () -> Void
    ) -> (any PendingTerminalInputObservation)? {
        // Legacy one-shot `addObserver(forName:.terminalSurfaceDidBecomeReady,
        // object: panel.surface, queue: .main)` keyed on the live surface. The
        // notification fires on the main queue but the closure is not main-isolated,
        // so hop to `@MainActor` before invoking `onReady`, matching the legacy
        // `Task { @MainActor in … }` body.
        guard let panel = panels[panelId] as? TerminalPanel else { return nil }
        let token = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: panel.surface,
            queue: .main
        ) { _ in
            Task { @MainActor in
                onReady()
            }
        }
        return ReadyObservation(token: token)
    }
}
