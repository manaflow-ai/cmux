public import CmuxTerminalCore

/// Runtime failures that can occur after producer input has been validated.
public enum TerminalOverlayMutationError: Error, Equatable, Sendable {
    case scrollbackGeometryUnavailable
}

extension TerminalSurface {
    /// Creates or replaces a keyed overlay through the surface's single retained store.
    @MainActor
    public func upsertTerminalOverlay(
        _ request: TerminalOverlayRequest
    ) -> Result<TerminalOverlay, TerminalOverlayMutationError> {
        let resolvedAnchor: TerminalOverlayAnchor
        switch request.anchor {
        case .viewportTop:
            resolvedAnchor = .viewportTop
        case .scrollbackTop:
            guard let captured = paneHost.captureTerminalOverlayScrollbackAnchor() else {
                return .failure(.scrollbackGeometryUnavailable)
            }
            resolvedAnchor = captured
        }

        let overlay = request.resolved(anchor: resolvedAnchor)
        terminalOverlayStore.upsert(overlay)
        paneHost.setTerminalOverlays(terminalOverlayStore.overlays)
        return .success(overlay)
    }

    /// Returns the current ordered overlay snapshot.
    @MainActor
    public func terminalOverlays() -> [TerminalOverlay] {
        terminalOverlayStore.overlays
    }

    /// Removes one keyed overlay without changing focus or terminal input state.
    @MainActor
    @discardableResult
    public func removeTerminalOverlay(id: String) -> Bool {
        let removed = terminalOverlayStore.remove(id: id)
        if removed {
            paneHost.setTerminalOverlays(terminalOverlayStore.overlays)
        }
        return removed
    }

    /// Removes every overlay owned by this surface.
    @MainActor
    @discardableResult
    public func removeAllTerminalOverlays() -> Int {
        let count = terminalOverlayStore.removeAll()
        if count > 0 {
            paneHost.setTerminalOverlays([])
        }
        return count
    }
}
