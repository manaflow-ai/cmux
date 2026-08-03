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
        case .scrollbackTop, .scrollbackSticky:
            guard let captured = paneHost.captureTerminalOverlayScrollbackAnchor(
                sticksToViewportTop: request.anchor == .scrollbackSticky
            ) else {
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

    /// Drops absolute-row overlays after Ghostty invalidates their row space.
    ///
    /// Reflow and bounded-scrollback eviction can renumber rows without a
    /// persistent row identity. Removing the stale resource is safer than
    /// rendering it over unrelated output.
    @MainActor
    @discardableResult
    public func removeInvalidatedTerminalOverlayAnchors(
        currentRowSpaceRevision: UInt64
    ) -> [String] {
        let removedIDs = terminalOverlayStore.removeInvalidatedScrollbackAnchors(
            currentRowSpaceRevision: currentRowSpaceRevision
        )
        if !removedIDs.isEmpty {
            paneHost.setTerminalOverlays(terminalOverlayStore.overlays)
        }
        return removedIDs
    }
}
