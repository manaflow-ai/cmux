internal import CMUXMobileCore
internal import Foundation

@MainActor
extension MobileShellComposite {
    /// Starts a foreground-Mac redial for an inline notification reply that
    /// arrived while the app is backgrounded.
    ///
    /// A locked phone has already run ``suspendForegroundRefresh()``, so the
    /// RPC channel the reply needs is gone and every automatic recovery
    /// entrypoint parks its trigger until the next foreground. The reply lane
    /// holds a `UIApplication` background task assertion for the dial's
    /// duration, which is what makes this one backgrounded dial safe
    /// (``RecoveryTrigger/permitsBackgroundedDial``).
    ///
    /// Selection-neutral: only the current foreground pairing is redialed,
    /// never switched. A reply that claims a different Mac keeps its parked
    /// state and is delivered by that Mac's own connection once available.
    /// - Parameter macDeviceID: The Mac claimed by the reply's push payload,
    ///   or `nil` for older payloads that always target the foreground Mac.
    public func recoverConnectionForBackgroundNotificationReply(
        macDeviceID: String?
    ) {
        guard isSignedIn, !connectionRequiresReauth else { return }
        if let macDeviceID, !macDeviceID.isEmpty,
           let foregroundTarget = foregroundMacDeviceID ?? recoveryTargetMacDeviceID,
           cmxCanonicalDeviceID(macDeviceID) != cmxCanonicalDeviceID(foregroundTarget) {
            return
        }
        // Straight redial, no probe. The reply lane kicks this only on direct
        // evidence the channel cannot deliver (a failed send, or a target the
        // suspended topology cannot resolve), and a probe that fails while
        // backgrounded is abandoned as inconclusive — which would swallow the
        // one dial the reply's background window allows.
        recoverMobileConnection(trigger: .backgroundNotificationReply)
    }
}
