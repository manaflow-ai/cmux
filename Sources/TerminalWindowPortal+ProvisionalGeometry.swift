import AppKit

// MARK: - Provisional pane geometry

extension WindowTerminalPortal {
    /// A model-projected frame applied ahead of the anchor's re-layout.
    ///
    /// bonsplit mutates its split tree synchronously, but the SwiftUI update
    /// that re-hosts the affected panes, and with it the `HostContainerView`
    /// anchor a hosted view follows, lands later. In that gap the hosted view
    /// would otherwise keep its pre-split frame and, being a transparent glyph
    /// layer above SwiftUI, paint over the new pane's chrome
    /// (https://github.com/manaflow-ai/cmux/issues/13387).
    ///
    /// The projection holds only while the anchor still reports the frame it
    /// had when the projection was applied. An anchor that moves or a new
    /// anchor binding hands geometry authority back to the anchor. The model
    /// owner releases a projection whose transaction no longer exists (a split
    /// closed again before SwiftUI rendered it), so a projection can never
    /// outlive the model state it was derived from.
    struct ProvisionalPaneGeometry: Equatable {
        /// The frame the hosted view had before the first projection of the
        /// current transaction; later projections re-derive from it.
        let baseFrameInHost: NSRect
        let frameInHost: NSRect
        /// The anchor's effective window frame when the projection was
        /// applied, or nil when the anchor had already left the window.
        let anchorFrameInWindow: NSRect?
        /// The model transaction the projection belongs to: the bonsplit split
        /// node it was derived from.
        let transactionID: UUID
    }

    /// Writes `frameInWindow` to a presented hosted view now and records it
    /// as that entry's provisional geometry.
    ///
    /// - Returns: Whether the entry accepted the projection.
    @discardableResult
    func applyProvisionalPaneFrame(
        _ frameInWindow: NSRect,
        forHostedId hostedId: ObjectIdentifier,
        transactionID: UUID
    ) -> Bool {
        guard var entry = entriesByHostedId[hostedId],
              let hostedView = entry.hostedView,
              isPresented(hostedView, hostedId: hostedId) else { return false }
        // Snap the edges, not origin and size: a projection puts the divider
        // on a half point while the pane's other edges stay where AppKit laid
        // them out, and those edges must not move by a pixel in the interim.
        let snapped = Self.edgeSnappedRect(hostView.convert(frameInWindow, from: nil), in: hostView)
        guard Self.isFiniteRect(snapped) else { return false }
        var frameInHost = snapped
        let clamped = snapped.intersection(hostView.bounds)
        if !clamped.isNull, clamped.width > 1, clamped.height > 1 {
            frameInHost = clamped
        }
        guard frameInHost.width > Self.tinyHideThreshold,
              frameInHost.height > Self.tinyHideThreshold else { return false }

        let anchorFrameInWindow = entry.anchorView.flatMap { anchor -> NSRect? in
            anchor.window === window ? effectiveAnchorFrameInWindow(for: anchor) : nil
        }
        let baseFrameInHost: NSRect = {
            guard let previous = entry.provisionalGeometry,
                  previous.transactionID == transactionID else { return hostedView.frame }
            return previous.baseFrameInHost
        }()
        entry.provisionalGeometry = ProvisionalPaneGeometry(
            baseFrameInHost: baseFrameInHost,
            frameInHost: frameInHost,
            anchorFrameInWindow: anchorFrameInWindow,
            transactionID: transactionID
        )
        entriesByHostedId[hostedId] = entry
#if DEBUG
        cmuxDebugLog(
            "portal.provisional.apply hosted=\(portalDebugToken(hostedView)) " +
            "anchor=\(portalDebugToken(entry.anchorView)) old=\(portalDebugFrame(hostedView.frame)) " +
            "frame=\(portalDebugFrame(frameInHost)) transaction=\(transactionID.uuidString.prefix(5)) " +
            "anchorFrame=\(anchorFrameInWindow.map(portalDebugFrame) ?? "nil")"
        )
#endif

        let expectedBounds = NSRect(origin: .zero, size: frameInHost.size)
        guard !Self.rectApproximatelyEqual(hostedView.frame, frameInHost) ||
            !Self.rectApproximatelyEqual(hostedView.bounds, expectedBounds) else { return true }
        performSelfFrameWrite {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedView.frame = frameInHost
            hostedView.bounds = expectedBounds
            CATransaction.commit()
        }
        _ = hostedView.reconcileGeometryNow()
        // The resting size is published by the settled pass, like any other
        // visible frame change; the redraw waits for the next main-queue turn
        // because this runs inside the caller's model mutation.
        markNeedsSettledCommit(for: hostedId)
        deferSurfaceRefresh(
            forHostedId: hostedId,
            reason: "portal.provisionalPaneFrame",
            transition: hostedView.terminalWorkTransition
        )
        scheduleExternalGeometrySynchronize(forceImmediate: false)
        return true
    }

    func provisionalPaneGeometry(forHostedId hostedId: ObjectIdentifier) -> ProvisionalPaneGeometry? {
        entriesByHostedId[hostedId]?.provisionalGeometry
    }

    /// The frame the hosted view had before the current transaction's first
    /// projection, in window points.
    func provisionalBaseFrameInWindow(forHostedId hostedId: ObjectIdentifier) -> NSRect? {
        entriesByHostedId[hostedId]?.provisionalGeometry.map {
            hostView.convert($0.baseFrameInHost, to: nil)
        }
    }

    /// The frame an anchor-driven pass writes for `hostedId`: the projection
    /// while the anchor still reports the frame it had when the projection
    /// was applied, otherwise the anchor's own frame, which releases it.
    func anchorTargetFrame(
        honoringProvisionalGeometryFor hostedId: ObjectIdentifier,
        entry: inout Entry,
        anchorFrameInWindow: NSRect,
        anchorFrameInHost: NSRect
    ) -> NSRect {
        guard let provisional = entry.provisionalGeometry else { return anchorFrameInHost }
        if let stamped = provisional.anchorFrameInWindow,
           Self.rectApproximatelyEqual(stamped, anchorFrameInWindow) {
            return provisional.frameInHost
        }
        entry.provisionalGeometry = nil
        entriesByHostedId[hostedId]?.provisionalGeometry = nil
#if DEBUG
        cmuxDebugLog(
            "portal.provisional.release hosted=\(portalDebugToken(entry.hostedView)) reason=anchorMoved " +
            "anchorFrame=\(portalDebugFrame(anchorFrameInWindow)) target=\(portalDebugFrame(anchorFrameInHost))"
        )
#endif
        return anchorFrameInHost
    }

    /// Bind seeds from the anchor unless the entry keeps a projection for
    /// that same anchor.
    func seededFrameInHost(for anchorView: NSView, hostedId: ObjectIdentifier) -> NSRect? {
        guard let seeded = seededFrameInHost(for: anchorView) else { return nil }
        guard var entry = entriesByHostedId[hostedId], entry.provisionalGeometry != nil else { return seeded }
        return anchorTargetFrame(
            honoringProvisionalGeometryFor: hostedId,
            entry: &entry,
            anchorFrameInWindow: effectiveAnchorFrameInWindow(for: anchorView),
            anchorFrameInHost: seeded
        )
    }

    /// Releases the projections of `workspaceID` whose transaction
    /// `isReleased` reports as gone and hands geometry back to their live
    /// anchors now. Entries whose anchor has already left the window simply
    /// drop the projection; their next bind seeds from the new anchor.
    func releaseProvisionalPaneGeometry(inWorkspace workspaceID: UUID, where isReleased: (UUID) -> Bool) {
        for (hostedId, entry) in entriesByHostedId {
            guard entry.workspaceID == workspaceID,
                  let provisional = entry.provisionalGeometry,
                  isReleased(provisional.transactionID) else { continue }
            entriesByHostedId[hostedId]?.provisionalGeometry = nil
#if DEBUG
            cmuxDebugLog(
                "portal.provisional.release hosted=\(portalDebugToken(entry.hostedView)) reason=transactionEnded " +
                "transaction=\(provisional.transactionID.uuidString.prefix(5))"
            )
#endif
            if let anchor = entry.anchorView, anchor.window === window {
                synchronizeHostedViewForAnchor(anchor, syncLayout: false)
            }
        }
    }

    private static func isFiniteRect(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.size.width.isFinite && rect.size.height.isFinite
    }

    /// Rounds each edge to the device pixel grid independently, so an edge
    /// that already sits on the grid is unchanged whatever the opposite
    /// edge does.
    private static func edgeSnappedRect(_ rect: NSRect, in view: NSView) -> NSRect {
        guard isFiniteRect(rect) else { return rect }
        let scale = max(1.0, view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0)
        func snap(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
        let minX = snap(rect.minX)
        let minY = snap(rect.minY)
        return NSRect(x: minX, y: minY, width: max(0, snap(rect.maxX) - minX), height: max(0, snap(rect.maxY) - minY))
    }
}

extension TerminalWindowPortalRegistry {
    private struct HostedPortal {
        let portal: WindowTerminalPortal
        let hostedId: ObjectIdentifier
    }

    private static func hostedPortal(for hostedView: GhosttySurfaceScrollView) -> HostedPortal? {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId[hostedId],
              let portal = portalsByWindowId[windowId] else { return nil }
        return HostedPortal(portal: portal, hostedId: hostedId)
    }

    @discardableResult
    static func applyProvisionalPaneFrame(
        _ frameInWindow: NSRect,
        for hostedView: GhosttySurfaceScrollView,
        transactionID: UUID
    ) -> Bool {
        guard let hosted = hostedPortal(for: hostedView) else { return false }
        return hosted.portal.applyProvisionalPaneFrame(
            frameInWindow,
            forHostedId: hosted.hostedId,
            transactionID: transactionID
        )
    }

    static func provisionalPaneGeometry(
        for hostedView: GhosttySurfaceScrollView
    ) -> WindowTerminalPortal.ProvisionalPaneGeometry? {
        guard let hosted = hostedPortal(for: hostedView) else { return nil }
        return hosted.portal.provisionalPaneGeometry(forHostedId: hosted.hostedId)
    }

    static func provisionalBaseFrameInWindow(for hostedView: GhosttySurfaceScrollView) -> NSRect? {
        guard let hosted = hostedPortal(for: hostedView) else { return nil }
        return hosted.portal.provisionalBaseFrameInWindow(forHostedId: hosted.hostedId)
    }

    /// Releases, in every window, the projections of `workspaceID` whose
    /// transaction `isReleased` reports as gone.
    static func releaseProvisionalPaneGeometry(inWorkspace workspaceID: UUID, where isReleased: (UUID) -> Bool) {
        for portal in portalsByWindowId.values {
            portal.releaseProvisionalPaneGeometry(inWorkspace: workspaceID, where: isReleased)
        }
    }
}
