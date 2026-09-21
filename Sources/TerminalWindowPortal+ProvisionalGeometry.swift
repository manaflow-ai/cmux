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
    /// had when the projection was applied. An anchor that moves, a new anchor
    /// binding, or a representable update observed after the projection that
    /// leaves the anchor in place all hand geometry authority back to the
    /// anchor, so a projection can never outlive the transaction it belongs to.
    struct ProvisionalPaneGeometry: Equatable {
        /// The frame the hosted view had before the first projection of the
        /// current transaction; later projections re-derive from it.
        let baseFrameInHost: NSRect
        let frameInHost: NSRect
        /// The anchor's effective window frame when the projection was
        /// applied, or nil when the anchor had already left the window.
        let anchorFrameInWindow: NSRect?
        /// Ordering token against representable updates (see
        /// `TerminalWindowPortalRegistry.provisionalGeometryEpoch`).
        let epoch: UInt64
    }

    /// Writes `frameInWindow` to a presented hosted view now and records it
    /// as that entry's provisional geometry.
    ///
    /// - Returns: Whether the entry accepted the projection.
    @discardableResult
    func applyProvisionalPaneFrame(_ frameInWindow: NSRect, forHostedId hostedId: ObjectIdentifier) -> Bool {
        guard var entry = entriesByHostedId[hostedId],
              let hostedView = entry.hostedView,
              isPresented(hostedView, hostedId: hostedId) else { return false }
        let snapped = Self.pixelSnappedRect(hostView.convert(frameInWindow, from: nil), in: hostView)
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
        TerminalWindowPortalRegistry.provisionalGeometryEpoch &+= 1
        entry.provisionalGeometry = ProvisionalPaneGeometry(
            baseFrameInHost: entry.provisionalGeometry?.baseFrameInHost ?? hostedView.frame,
            frameInHost: frameInHost,
            anchorFrameInWindow: anchorFrameInWindow,
            epoch: TerminalWindowPortalRegistry.provisionalGeometryEpoch
        )
        entriesByHostedId[hostedId] = entry
#if DEBUG
        cmuxDebugLog(
            "portal.provisional.apply hosted=\(portalDebugToken(hostedView)) " +
            "anchor=\(portalDebugToken(entry.anchorView)) old=\(portalDebugFrame(hostedView.frame)) " +
            "frame=\(portalDebugFrame(frameInHost)) " +
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

    /// Hands authority back to a live anchor that a representable update
    /// observed after the projection left in place.
    func releaseProvisionalPaneGeometry(
        forHostedId hostedId: ObjectIdentifier,
        boundTo anchorView: NSView,
        observedEpoch: UInt64
    ) {
        guard let entry = entriesByHostedId[hostedId],
              let provisional = entry.provisionalGeometry,
              observedEpoch >= provisional.epoch,
              entry.anchorView === anchorView,
              anchorView.window === window else { return }
        entriesByHostedId[hostedId]?.provisionalGeometry = nil
#if DEBUG
        cmuxDebugLog(
            "portal.provisional.release hosted=\(portalDebugToken(entry.hostedView)) reason=anchorSettled " +
            "epoch=\(provisional.epoch) observed=\(observedEpoch)"
        )
#endif
        synchronizeHostedViewForAnchor(anchorView, syncLayout: false)
    }

    private static func isFiniteRect(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.size.width.isFinite && rect.size.height.isFinite
    }
}

extension TerminalWindowPortalRegistry {
    /// Monotonic token bumped on every projection. A representable update
    /// staged with an older token predates the projection and must not
    /// release it; one staged with a newer token observed SwiftUI's reaction
    /// to the mutation and may.
    static var provisionalGeometryEpoch: UInt64 = 0

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
    static func applyProvisionalPaneFrame(_ frameInWindow: NSRect, for hostedView: GhosttySurfaceScrollView) -> Bool {
        guard let hosted = hostedPortal(for: hostedView) else { return false }
        return hosted.portal.applyProvisionalPaneFrame(frameInWindow, forHostedId: hosted.hostedId)
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

    static func releaseProvisionalPaneGeometry(
        for hostedView: GhosttySurfaceScrollView,
        boundTo anchorView: NSView,
        observedEpoch: UInt64
    ) {
        guard let hosted = hostedPortal(for: hostedView) else { return }
        hosted.portal.releaseProvisionalPaneGeometry(
            forHostedId: hosted.hostedId,
            boundTo: anchorView,
            observedEpoch: observedEpoch
        )
    }
}
