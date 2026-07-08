import AppKit
import CoreGraphics
import Foundation

// CoreGraphics requires a C callback; this trampoline only forwards to AppDelegate on the main queue.
private func cmuxDisplayReconfigurationCallback(
    _ _: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    let isBeginning = flags.contains(.beginConfigurationFlag)
    NotificationCenter.default.post(
        name: Notification.Name("com.cmuxterm.app.displayReconfiguration"),
        object: appDelegate,
        userInfo: ["isBeginning": isBeginning]
    )
}

extension AppDelegate {
    /// The signature of the currently-connected display configuration, used as
    /// the key for per-monitor window-geometry memory. `nil` when no display has
    /// a stable identity (nothing can be persisted reliably) or when displays are
    /// mid-reconfiguration with degenerate frames.
    func currentDisplayConfigurationSignature() -> String? {
        currentDisplayGeometries().available
            .displayConfigurationSignature(isMirrored: Self.displaysAreMirrored())
    }

    /// Whether the connected displays form a mirrored set (any two share a
    /// CoreGraphics mirror relationship). Mirroring is surfaced so a mirrored
    /// configuration never collides with a single-display signature.
    nonisolated static func displaysAreMirrored() -> Bool {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            return false
        }

        var displayIDs = [CGDirectDisplayID](repeating: kCGNullDirectDisplay, count: Int(displayCount))
        let error = displayIDs.withUnsafeMutableBufferPointer { buffer in
            CGGetOnlineDisplayList(displayCount, buffer.baseAddress, &displayCount)
        }
        guard error == .success else { return false }

        for displayID in displayIDs.prefix(Int(displayCount)) {
            if CGDisplayIsInMirrorSet(displayID) != 0
                || CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay {
                return true
            }
        }
        return false
    }

    func displaySnapshot(for window: NSWindow?) -> SessionDisplaySnapshot? {
        guard let window else { return nil }
        let screen = window.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })
        guard let screen else { return nil }

        return SessionDisplaySnapshot(
            displayID: screen.cmuxDisplayID,
            stableID: screen.cmuxStableDisplayKey,
            frame: SessionRectSnapshot(screen.frame),
            visibleFrame: SessionRectSnapshot(screen.visibleFrame)
        )
    }

    /// Consumes the current display-change notification state: first restores
    /// each window's remembered frame for the now-connected configuration
    /// (issue #2135), then re-clamps any window whose titlebar is still
    /// unreachable (#6913 safety net).
    ///
    /// CoreGraphics/AppKit display-change callbacks advance the display
    /// generation. CoreGraphics callbacks only invalidate any previously
    /// reconciled release signature; AppKit's screen-parameters notification
    /// owns the reconcile scheduling. The capture firewall is only released by
    /// a later capture attempt that observes the reconciled signature from the
    /// latest generation. A nil signature leaves the previous restore baseline
    /// intact.
    func scheduleScreenChangeReconcileWhenIdle() {
        NotificationQueue.default.enqueue(
            Notification(name: Self.screenChangeReconcileNotification, object: self),
            postingStyle: .whenIdle,
            coalesceMask: [.onName, .onSender],
            forModes: nil
        )
    }

    func registerDisplayReconfigurationCallbackIfNeeded() {
        guard !didRegisterDisplayReconfigurationCallback else { return }
        let result = CGDisplayRegisterReconfigurationCallback(
            cmuxDisplayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        didRegisterDisplayReconfigurationCallback = result == .success
    }

    func unregisterDisplayReconfigurationCallbackIfNeeded() {
        guard didRegisterDisplayReconfigurationCallback else { return }
        CGDisplayRemoveReconfigurationCallback(
            cmuxDisplayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        didRegisterDisplayReconfigurationCallback = false
    }

    func handleDisplayReconfiguration(isBeginning _: Bool) {
        displayReconfigurationGeneration += 1
        beginScreenChangeCaptureSuppression()
    }

    func handleScreenParametersDidChange() {
        displayReconfigurationGeneration += 1
        beginScreenChangeCaptureSuppression()
        scheduleScreenChangeReconcileWhenIdle()
    }

    func reconcileMainWindowFramesAfterScreenChange() {
        // Never fight a deliberate frame the restore path or teardown is
        // applying, and never persist a frame clamped against transient
        // mid-teardown geometry. Leaving suppression armed fails closed; restore
        // completion reruns this pass if a screen change was skipped.
        guard !isApplyingSessionRestore, !isTerminatingApp else { return }
        let displays = currentDisplayGeometries()
        guard !displays.available.isEmpty else {
            requeueScreenChangeReconcileIfPossible()
            return
        }

        // Restore remembered per-configuration frames only when the connected
        // display set genuinely changed — so sleep/wake and Dock resize (same
        // signature) never reposition a deliberately-placed window.
        let signature = displays.available
            .displayConfigurationSignature(isMirrored: Self.displaysAreMirrored())
        let signatureChanged = signature.map {
            didObserveUnknownDisplayConfiguration || $0 != lastAppliedConfigurationSignature
        } ?? false
#if DEBUG
        cmuxDebugLog(
            "monitorMemory.reconcile displays=\(displays.available.count) " +
                "sigChanged=\(signatureChanged ? 1 : 0) " +
                "was=\(Self.signatureLogToken(lastAppliedConfigurationSignature)) " +
                "now=\(Self.signatureLogToken(signature))"
        )
#endif
        if let signature {
            if signatureChanged {
                restoreRememberedFrames(for: signature, displays: displays)
            }
            lastAppliedConfigurationSignature = signature
            didObserveUnknownDisplayConfiguration = false
            screenChangeReconcileRetryBudget = 0
            if isScreenChangeCaptureSuppressed {
                screenChangeCaptureSuppressionSignature = signature
                screenChangeCaptureSuppressionSignatureGeneration = displayReconfigurationGeneration
            }
        } else {
            didObserveUnknownDisplayConfiguration = true
            requeueScreenChangeReconcileIfPossible()
        }

        // Reachability safety net: any window still stranded is clamped back.
        let mainWindows = mainWindowsForVisibilityController()
        for window in mainWindows {
            // Native-fullscreen windows are owned by AppKit's Space machinery;
            // clamping them mid-transition fights the fullscreen teardown.
            guard !window.styleMask.contains(.fullScreen) else { continue }
            let currentFrame = window.frame
            guard let corrected = Self.reconciledFrameAfterScreenChange(
                frame: currentFrame,
                availableDisplays: displays.available
            ) else { continue }
#if DEBUG
            cmuxDebugLog(
                "window.reconcile " +
                    "from={\(nsRectLogDescription(currentFrame))} " +
                    "to={\(nsRectLogDescription(corrected))}"
            )
#endif
            window.setFrame(corrected, display: true)
        }
        mainWindowVisibleFrameFitRescue.performFitIfNeeded(
            displays: displays.available,
            windows: mainWindows
        )
    }

    /// Restores each window's remembered frame for `signature`, routed through
    /// `resolvedWindowFrame` (so a remembered frame that no longer fits is
    /// re-clamped rather than applied raw). Fullscreen windows are skipped.
    func restoreRememberedFrames(
        for signature: String,
        displays: (available: [SessionDisplayGeometry], fallback: SessionDisplayGeometry?)
    ) {
        for window in mainWindowsForVisibilityController() {
            guard !window.styleMask.contains(.fullScreen) else { continue }
            guard let context = contextForMainTerminalWindow(window) else { continue }
            let windowTag = context.windowId.uuidString.prefix(8)
            guard let entry = windowConfigFrames[context.windowId]?.entry(for: signature) else {
#if DEBUG
                let known = windowConfigFrames[context.windowId]?.entries.count ?? 0
                cmuxDebugLog(
                    "monitorMemory.restore.miss window=\(windowTag) " +
                        "sig=\(Self.signatureLogToken(signature)) rememberedConfigs=\(known)"
                )
#endif
                continue
            }
            guard let restored = Self.resolvedWindowFrame(
                from: entry.frame,
                display: entry.display,
                availableDisplays: displays.available,
                fallbackDisplay: displays.fallback
            ) else { continue }
#if DEBUG
            cmuxDebugLog(
                "monitorMemory.restore.hit window=\(windowTag) " +
                    "sig=\(Self.signatureLogToken(signature)) " +
                    "remembered={\(sessionRectLogDescription(entry.frame))} " +
                    "applied={\(nsRectLogDescription(restored))}"
            )
#endif
            window.setFrame(restored, display: true)
        }
    }

    nonisolated static func resolvedWindowFrame(
        from snapshot: SessionWindowSnapshot?,
        currentSignature: String?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?
    ) -> CGRect? {
        let source = preferredWindowFrameSource(from: snapshot, currentSignature: currentSignature)
        return resolvedWindowFrame(
            from: source.frame,
            display: source.display,
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        )
    }

    private nonisolated static func preferredWindowFrameSource(
        from snapshot: SessionWindowSnapshot?,
        currentSignature: String?
    ) -> (frame: SessionRectSnapshot?, display: SessionDisplaySnapshot?) {
        if let currentSignature,
           let entry = SessionConfigFrameRing(entries: snapshot?.configFrames ?? [])
               .entry(for: currentSignature) {
            return (entry.frame, entry.display)
        }
        return (snapshot?.frame, snapshot?.display)
    }

    nonisolated static func displayMatchingSnapshotGeometry(
        for snapshot: SessionDisplaySnapshot,
        in displays: [SessionDisplayGeometry]
    ) -> SessionDisplayGeometry? {
        guard let referenceRect = (snapshot.visibleFrame ?? snapshot.frame)?.cgRect else {
            return nil
        }
        let overlaps = displays.map { display -> (display: SessionDisplayGeometry, area: CGFloat) in
            (display, intersectionArea(referenceRect, display.visibleFrame))
        }
        if let bestOverlap = overlaps.max(by: { $0.area < $1.area }), bestOverlap.area > 0 {
            return bestOverlap.display
        }

        let referenceCenter = CGPoint(x: referenceRect.midX, y: referenceRect.midY)
        return displays.min { lhs, rhs in
            distanceSquared(lhs.visibleFrame, referenceCenter) < distanceSquared(rhs.visibleFrame, referenceCenter)
        }
    }

    /// Records `window`'s current frame under the current display signature —
    /// unless a guard forbids it. The guards are the corruption firewall for
    /// issue #2135: a window's good frame must never be overwritten by a
    /// transient/OS-driven frame during a display flap.
    func captureWindowConfigFrame(_ window: NSWindow, reason: String) {
        // 1. Never capture a deliberately-applied restore or teardown frame.
        guard !isApplyingSessionRestore,
              (!isTerminatingApp || reason == "sessionSnapshot") else {
            logCaptureSkipped(window, reason: reason, guardName: "restore/teardown")
            return
        }
        // 2. Fullscreen windows have no meaningful per-config frame to remember.
        guard !window.styleMask.contains(.fullScreen) else {
            logCaptureSkipped(window, reason: reason, guardName: "fullscreen")
            return
        }
        guard let context = contextForMainTerminalWindow(window) else {
            logCaptureSkipped(window, reason: reason, guardName: "noContext")
            return
        }

        let displays = currentDisplayGeometries()
        // 3. Key to the WRITE-TIME signature so a slipped write can only land in
        //    the currently-connected slot, never overwrite a disconnected one.
        guard let signature = displays.available
            .displayConfigurationSignature(isMirrored: Self.displaysAreMirrored())
        else {
            logCaptureSkipped(window, reason: reason, guardName: "noStableSignature")
            return
        }

        let frame = window.frame
        // 4. Never persist a stranded/transient frame: if the reconcile logic
        //    would move this frame, it is not a good frame to remember.
        guard Self.reconciledFrameAfterScreenChange(
            frame: frame,
            availableDisplays: displays.available
        ) == nil else {
            logCaptureSkipped(window, reason: reason, guardName: "strandedFrame")
            return
        }
        if isScreenChangeCaptureSuppressed {
            guard screenChangeCaptureSuppressionSignature != nil else {
                screenChangeReconcileRetryBudget = max(screenChangeReconcileRetryBudget, 1)
                scheduleScreenChangeReconcileWhenIdle()
                logCaptureSkipped(window, reason: reason, guardName: "screenChangeNeedsReconcile")
                return
            }
            guard shouldReleaseScreenChangeCaptureSuppression(for: signature) else {
                logCaptureSkipped(window, reason: reason, guardName: "screenChange")
                return
            }
            isScreenChangeCaptureSuppressed = false
            screenChangeCaptureSuppressionSignature = nil
        }

        let entry = SessionConfigFrameEntry(
            signature: signature,
            frame: SessionRectSnapshot(frame),
            display: displaySnapshot(for: window),
            lastUsedAt: Date().timeIntervalSince1970
        )
        let existing = windowConfigFrames[context.windowId] ?? SessionConfigFrameRing()
        windowConfigFrames[context.windowId] = existing.upserting(entry)
#if DEBUG
        cmuxDebugLog(
            "monitorMemory.capture window=\(context.windowId.uuidString.prefix(8)) " +
                "reason=\(reason) sig=\(Self.signatureLogToken(signature)) " +
                "frame={\(nsRectLogDescription(frame))} " +
                "rememberedConfigs=\(windowConfigFrames[context.windowId]?.entries.count ?? 0)"
        )
#endif
    }

    func logCaptureSkipped(_ window: NSWindow, reason: String, guardName: String) {
#if DEBUG
        let tag = contextForMainTerminalWindow(window)?.windowId.uuidString.prefix(8) ?? "??"
        cmuxDebugLog(
            "monitorMemory.capture.skip window=\(tag) reason=\(reason) guard=\(guardName) " +
                "frame={\(nsRectLogDescription(window.frame))}"
        )
#endif
    }

#if DEBUG
    /// Compact, human-readable rendering of a config signature for the debug log
    /// (the full signature can be long with several displays).
    nonisolated static func signatureLogToken(_ signature: String?) -> String {
        guard let signature else { return "nil" }
        // Show the display count and a short hash-ish suffix so transitions are
        // visible without dumping the whole key.
        let displayCount = signature.split(separator: "|").count
        let tail = signature.suffix(20)
        return "[\(displayCount)d …\(tail)]"
    }
#endif

    /// Arms the capture firewall for a display reconfiguration.
    ///
    /// This stays armed until the CoreGraphics display transaction has ended
    /// and a reconcile pass records the current configuration signature. If
    /// restore, teardown, or an empty display list skips that pass, captures
    /// remain suppressed rather than reopening on elapsed time.
    func beginScreenChangeCaptureSuppression() {
        isScreenChangeCaptureSuppressed = true
        screenChangeCaptureSuppressionSignature = nil
        screenChangeCaptureSuppressionSignatureGeneration = nil
        screenChangeReconcileRetryBudget = Self.screenChangeReconcileRetryLimit
    }

    func shouldReleaseScreenChangeCaptureSuppression(for signature: String) -> Bool {
        guard isScreenChangeCaptureSuppressed else { return true }
        return screenChangeCaptureSuppressionSignature == signature
            && screenChangeCaptureSuppressionSignatureGeneration == displayReconfigurationGeneration
    }

    func requeueScreenChangeReconcileIfPossible() {
        guard isScreenChangeCaptureSuppressed, screenChangeReconcileRetryBudget > 0 else {
            return
        }
        screenChangeReconcileRetryBudget -= 1
        scheduleScreenChangeReconcileWhenIdle()
    }
}
