public import Foundation
internal import GhosttyKit
internal import CmuxTerminalCore
internal import CmuxFoundation

/// One registered waiter for a tokened render-presented acknowledgment.
///
/// `expiresAt` bounds bookkeeping only: a waiter whose forced draw was skipped
/// by the renderer (unrealized renderer, zero-sized surface, size-discarded
/// layer assignment) never receives its callback, so stale entries are pruned
/// opportunistically on later registrations instead of leaking until surface
/// teardown. The caller's own timeout (the socket-worker callback awaiter)
/// remains the authoritative failure signal.
struct TerminalSurfacePresentedFrameWaiter {
    let expiresAt: Date
    let onPresented: @MainActor () -> Void
}

/// The libghostty render-presented callback (cmux fork C API). Ghostty invokes
/// it on the main thread, in the same dispatched block that assigned the
/// frame's IOSurface to the layer, so the layer's `contents` observed from the
/// waiter is at least as new as the acknowledged frame.
private let terminalGhosttyRenderPresentedCallback:
    ghostty_render_presented_cb = { userdata, token in
        guard let userdata else { return }
        let userdataAddress = UInt(bitPattern: userdata)
        MainActor.assumeIsolated {
            guard let mainActorUserdata =
                    UnsafeMutableRawPointer(bitPattern: userdataAddress) else {
                return
            }
            let context = Unmanaged<GhosttySurfaceCallbackContext>
                .fromOpaque(mainActorUserdata)
                .takeUnretainedValue()
            guard let surface =
                    context.surfaceController as? TerminalSurface else {
                return
            }
            surface.deliverRenderPresentedToken(token)
        }
    }

extension TerminalSurface {
    /// The lifetime bound for stale-waiter pruning. Comfortably above every
    /// socket-side capture timeout so a pruned entry can never race a waiter
    /// whose caller is still blocked.
    private static let presentedFrameWaiterLifetime: TimeInterval = 60

    /// Monotonic token source for tokened renders. An atomic (not main-actor
    /// state) so nonisolated callers can mint tokens before hopping to main.
    private static let presentedFrameTokenSource = AtomicUInt64Value(1)

    /// Mints a process-unique nonzero token for one tokened render.
    public static func makePresentedFrameToken() -> UInt64 {
        presentedFrameTokenSource.wrappingIncrementRelaxed()
    }

    /// Installs the per-runtime-surface render-presented callback. Called once
    /// directly after `ghostty_surface_new`, mirroring
    /// `installFontSizeActionObservation`.
    @MainActor
    func installRenderPresentedObservation(
        on runtimeSurface: ghostty_surface_t,
        callbackContext: Unmanaged<GhosttySurfaceCallbackContext>
    ) {
        precondition(
            ghostty_surface_set_render_presented_callback(
                runtimeSurface,
                terminalGhosttyRenderPresentedCallback,
                callbackContext.toOpaque()
            ),
            "Each Ghostty surface installs one render-presented callback"
        )
    }

    /// Requests one forced renderer-thread frame whose presentation is
    /// acknowledged with `token`, invoking `onPresented` on the main actor
    /// after the exact frame's IOSurface has been assigned to the layer.
    ///
    /// Returns false without retaining `onPresented` when the surface has no
    /// live runtime pointer or the runtime refused the request (no callback
    /// installed, or another tokened draw is still pending). The caller owns
    /// timeout handling; `cancelPresentedFrameWaiter` withdraws a waiter whose
    /// caller gave up.
    @MainActor
    public func requestPresentedFrame(
        token: UInt64,
        onPresented: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let surface = liveSurfaceForGhosttyAccess(
            reason: "renderer.requestPresentedFrame"
        ) else { return false }
        prunePresentedFrameWaiters(now: Date())
        pendingRenderPresentedWaiters[token] = TerminalSurfacePresentedFrameWaiter(
            expiresAt: Date().addingTimeInterval(Self.presentedFrameWaiterLifetime),
            onPresented: onPresented
        )
        guard ghostty_surface_request_render_with_token(surface, token) else {
            pendingRenderPresentedWaiters.removeValue(forKey: token)
            return false
        }
        return true
    }

    /// Withdraws a waiter whose caller timed out or was cancelled.
    @MainActor
    public func cancelPresentedFrameWaiter(token: UInt64) {
        pendingRenderPresentedWaiters.removeValue(forKey: token)
    }

    /// Completes the waiter registered for `token`, if any. Tokens without a
    /// waiter (already cancelled, or minted by another consumer of the tokened
    /// render API) are ignored.
    @MainActor
    func deliverRenderPresentedToken(_ token: UInt64) {
        guard let waiter =
                pendingRenderPresentedWaiters.removeValue(forKey: token) else {
            return
        }
        waiter.onPresented()
    }

    @MainActor
    private func prunePresentedFrameWaiters(now: Date) {
        guard !pendingRenderPresentedWaiters.isEmpty else { return }
        pendingRenderPresentedWaiters = pendingRenderPresentedWaiters.filter {
            $0.value.expiresAt > now
        }
    }
}
