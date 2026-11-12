public import AppKit
public import CoreGraphics
public import CmuxTerminalCore
#if DEBUG
internal import CMUXDebugLog
#endif

// MARK: - Committed pane geometry

extension TerminalSurface {
    /// The smallest size a terminal starts at while no host shows it, in
    /// points. Matches the headless bootstrap window so an unseen pane never
    /// spawns its PTY from a clipped placeholder frame.
    static let hiddenPaneDefaultSize = CGSize(width: 800, height: 600)

    /// Publishes a pane size the host has established as user-visible.
    ///
    /// This is the only entry through which view geometry reaches the
    /// renderer grid and the PTY. Hosts call it from a settled layout pass or
    /// from a drag tick, never from an intermediate frame. When no runtime
    /// surface exists yet, the commit records the size and starts a creation
    /// that was waiting for it, so the PTY's first window size is this one.
    ///
    /// - Parameter geometry: The committed pane size, scale, and phase.
    /// - Returns: Whether the renderer or PTY size changed.
    @MainActor
    @discardableResult
    public func commitPaneGeometry(_ geometry: TerminalPaneGeometry) -> Bool {
        committedPaneGeometry = geometry
        guard surface != nil else {
            startPendingRuntimeSurfaceCreationIfNeeded()
            return false
        }
        return applyCommittedPaneGeometry(geometry, caller: "commitPaneGeometry")
    }

    /// Forgets the committed size when the host stops presenting the pane.
    ///
    /// The runtime keeps its last grid; nothing is published. A later commit
    /// from the next presenting host supplies the next size.
    @MainActor
    public func clearPaneGeometry() {
        committedPaneGeometry = nil
    }

    /// Re-applies the committed size, for example after the runtime surface
    /// is recreated or the renderer needs a synchronous size confirmation.
    ///
    /// - Returns: Whether the renderer or PTY size changed.
    @MainActor
    @discardableResult
    public func reapplyCommittedPaneGeometry() -> Bool {
        guard let geometry = committedPaneGeometry else { return false }
        guard surface != nil else {
            startPendingRuntimeSurfaceCreationIfNeeded()
            return false
        }
        return applyCommittedPaneGeometry(geometry, caller: "reapplyCommittedPaneGeometry")
    }

    @MainActor
    func applyCommittedPaneGeometry(_ geometry: TerminalPaneGeometry, caller: StaticString) -> Bool {
        let interactive = geometry.phase == .interactive
        let coalescePixelOnlyResize = TerminalSurfaceResizeCoalescingPolicy(
            windowLiveResizeActive: interactive,
            interactiveGeometryResizeActive: interactive,
            // A settled commit is the resting size; apply it exactly.
            bypass: !interactive,
            surfaceKind: ioMode == .exec ? .processOwned : .manualIO
        ).shouldCoalescePixelOnlyResize
        return updateSize(
            width: geometry.size.width,
            height: geometry.size.height,
            xScale: geometry.backingScale,
            yScale: geometry.backingScale,
            layerScale: geometry.backingScale,
            backingSize: geometry.backingSize,
            coalescePixelOnlyResize: coalescePixelOnlyResize,
            // A tmux-assigned grid pin would hold the mirror at the pre-drag
            // size and paint past the shrinking pane; re-pin at rest.
            suppressAssignedGridPin: interactive,
            caller: caller
        )
    }

    /// Starts a runtime creation that ``createSurface(for:source:)`` parked
    /// because the portal-owned view had no committed geometry yet.
    @MainActor
    func startPendingRuntimeSurfaceCreationIfNeeded() {
        guard let source = pendingRuntimeSurfaceCreationSource,
              surface == nil,
              committedPaneGeometry != nil,
              let view = attachedView else { return }
        pendingRuntimeSurfaceCreationSource = nil
#if DEBUG
        logDebugEvent(
            "surface.create.resume surface=\(id.uuidString.prefix(5)) reason=paneGeometryCommitted"
        )
#endif
        createSurface(for: view, source: source)
    }

    /// Parks a runtime creation whose portal-owned, visible view has no
    /// committed pane geometry yet.
    ///
    /// Creating the runtime before the commit would give the PTY an initial
    /// window size from a frame the user never saw, and a resumed TUI reflows
    /// to it permanently. A pane the portal is not showing has no visible size
    /// at all; it starts at the default size like a restored upstream window
    /// and reflows once when revealed, so it is not parked.
    ///
    /// - Returns: Whether the creation was parked.
    @MainActor
    func parkRuntimeSurfaceCreationIfAwaitingPaneGeometry(
        view: any TerminalSurfaceNativeViewing,
        source: RuntimeSurfaceCreationSource
    ) -> Bool {
        guard view.paneGeometryIsPortalOwned, committedPaneGeometry == nil, rendererPortalVisible else {
            pendingRuntimeSurfaceCreationSource = nil
            return false
        }
        pendingRuntimeSurfaceCreationSource =
            pendingRuntimeSurfaceCreationSource.map { $0.promoted(with: source) } ?? source
#if DEBUG
        logDebugEvent(
            "surface.create.wait surface=\(id.uuidString.prefix(5)) reason=noCommittedPaneGeometry " +
            "bounds=\(String(format: "%.1fx%.1f", Double(view.bounds.width), Double(view.bounds.height)))"
        )
#endif
        return true
    }

    /// The pixel size a new runtime surface starts at.
    ///
    /// The committed pane geometry is the size the user sees. A portal-owned
    /// view without one is hidden, and its bounds may be a clipped
    /// placeholder, so it starts no smaller than the default size. A view
    /// outside a portal sizes from its own bounds, as upstream does.
    @MainActor
    func initialRuntimeBackingSize(for view: any TerminalSurfaceNativeViewing) -> CGSize {
        if let committed = committedPaneGeometry { return committed.backingSize }
        var points = view.bounds.size
        if view.paneGeometryIsPortalOwned {
            points.width = max(points.width, Self.hiddenPaneDefaultSize.width)
            points.height = max(points.height, Self.hiddenPaneDefaultSize.height)
        }
        return view.convertToBacking(NSRect(origin: .zero, size: points)).size
    }
}
