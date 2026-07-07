import AppKit
import Foundation

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
    /// screen origin+size). Mirroring is surfaced so a mirrored configuration
    /// never collides with a single-display signature.
    nonisolated static func displaysAreMirrored() -> Bool {
        let frames = NSScreen.screens.map(\.frame)
        for i in frames.indices {
            for j in frames.indices where j > i {
                if frames[i].equalTo(frames[j]) { return true }
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

    /// Coalesces bursts of `didChangeScreenParametersNotification` into a single
    /// reconcile pass. The display list often arrives in stages during a
    /// reconfiguration (a monitor connecting, resolution ramping, the lid
    /// animating), so a short bounded delay lets `NSScreen` settle before we read
    /// it back; restarting the delay on each notification collapses the burst
    /// into one pass keyed off the last event. The pending task is cancelled on
    /// teardown so it can never fire against a half-torn-down app.
    func scheduleMainWindowFrameReconcile() {
        mainWindowFrameReconcileTask?.cancel()
        mainWindowFrameReconcileTask = Task { @MainActor [weak self] in
            // Bounded settle delay; cancellation (teardown / a newer event)
            // aborts it structurally.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.mainWindowFrameReconcileTask = nil
            self.reconcileMainWindowFramesAfterScreenChange()
        }
    }

    /// Runs after a display reconfiguration settles: first restores each
    /// window's remembered frame for the now-connected configuration (issue
    /// #2135), then re-clamps any window whose titlebar is still unreachable
    /// (#6913 safety net).
    ///
    /// macOS exposes no public whole-transaction completion callback for display
    /// reconfiguration. `CGDisplayRegisterReconfigurationCallback` reports
    /// per-display after-flags, and
    /// `NSApplication.didChangeScreenParametersNotification` is a stream, not a
    /// transaction boundary. Quiescence of that notification stream (the 200ms
    /// debounce in `scheduleMainWindowFrameReconcile`) is the only
    /// platform-observable settle signal. The capture firewall therefore clears
    /// only when this pass consumes the settled display list and records the
    /// latest signature; skipped passes leave captures closed.
    func reconcileMainWindowFramesAfterScreenChange() {
        // Never fight a deliberate frame the restore path or teardown is
        // applying, and never persist a frame clamped against transient
        // mid-teardown geometry. Leaving settling armed fails closed; restore
        // completion reschedules this pass if a screen change was skipped.
        guard !isApplyingSessionRestore, !isTerminatingApp else { return }
        let displays = currentDisplayGeometries()
        guard !displays.available.isEmpty else { return }

        // Restore remembered per-configuration frames only when the connected
        // display set genuinely changed — so sleep/wake and Dock resize (same
        // signature) never reposition a deliberately-placed window.
        let signature = displays.available
            .displayConfigurationSignature(isMirrored: Self.displaysAreMirrored())
        let signatureChanged = signature != lastAppliedConfigurationSignature
#if DEBUG
        cmuxDebugLog(
            "monitorMemory.reconcile displays=\(displays.available.count) " +
                "sigChanged=\(signatureChanged ? 1 : 0) " +
                "was=\(Self.debugSignatureToken(lastAppliedConfigurationSignature)) " +
                "now=\(Self.debugSignatureToken(signature))"
        )
#endif
        if let signature, signatureChanged {
            restoreRememberedFrames(for: signature, displays: displays)
        }
        lastAppliedConfigurationSignature = signature
        isSettlingScreenChange = false

        // Reachability safety net: any window still stranded is clamped back.
        for window in mainWindowsForVisibilityController() {
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
                    "from={\(debugNSRectDescription(currentFrame))} " +
                    "to={\(debugNSRectDescription(corrected))}"
            )
#endif
            window.setFrame(corrected, display: true)
        }
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
            guard let entry = SessionConfigFramePolicy.entry(
                for: signature,
                in: windowConfigFrames[context.windowId]
            ) else {
#if DEBUG
                let known = (windowConfigFrames[context.windowId] ?? []).count
                cmuxDebugLog(
                    "monitorMemory.restore.miss window=\(windowTag) " +
                        "sig=\(Self.debugSignatureToken(signature)) rememberedConfigs=\(known)"
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
                    "sig=\(Self.debugSignatureToken(signature)) " +
                    "remembered={\(debugSessionRectDescription(entry.frame))} " +
                    "applied={\(debugNSRectDescription(restored))}"
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
           let entry = SessionConfigFramePolicy.entry(
               for: currentSignature,
               in: snapshot?.configFrames
           ) {
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
        // 1. Never capture a deliberately-applied restore frame or a teardown
        //    frame, and never during the settling window after a screen change
        //    (except the leading-edge capture, which runs before settling arms).
        guard !isApplyingSessionRestore,
              (!isTerminatingApp || reason == "sessionSnapshot"),
              !isSettlingScreenChange else {
            logCaptureSkipped(window, reason: reason, guardName: "settling/restore/teardown")
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

        let entry = SessionConfigFrameEntry(
            signature: signature,
            frame: SessionRectSnapshot(frame),
            display: displaySnapshot(for: window),
            lastUsedAt: Date().timeIntervalSince1970
        )
        windowConfigFrames[context.windowId] = SessionConfigFramePolicy.merged(
            windowConfigFrames[context.windowId] ?? [],
            upserting: entry
        )
#if DEBUG
        cmuxDebugLog(
            "monitorMemory.capture window=\(context.windowId.uuidString.prefix(8)) " +
                "reason=\(reason) sig=\(Self.debugSignatureToken(signature)) " +
                "frame={\(debugNSRectDescription(frame))} " +
                "rememberedConfigs=\(windowConfigFrames[context.windowId]?.count ?? 0)"
        )
#endif
    }

    func logCaptureSkipped(_ window: NSWindow, reason: String, guardName: String) {
#if DEBUG
        let tag = contextForMainTerminalWindow(window)?.windowId.uuidString.prefix(8) ?? "??"
        cmuxDebugLog(
            "monitorMemory.capture.skip window=\(tag) reason=\(reason) guard=\(guardName) " +
                "frame={\(debugNSRectDescription(window.frame))}"
        )
#endif
    }

#if DEBUG
    /// Compact, human-readable rendering of a config signature for the debug log
    /// (the full signature can be long with several displays).
    nonisolated static func debugSignatureToken(_ signature: String?) -> String {
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
    /// macOS provides only a stream of display-change notifications, not a
    /// public "display transaction complete" callback. This stays armed until a
    /// reconcile pass consumes a quiesced `NSScreen` list and records the current
    /// configuration signature. If restore, teardown, or an empty display list
    /// skips that pass, captures remain suppressed rather than reopening on
    /// elapsed time.
    func beginSettlingScreenChange() {
        isSettlingScreenChange = true
    }
}
