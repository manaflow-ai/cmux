public import AppKit
public import CmuxNextDesignTokens

extension MotionPolicy {
    /// How a main window comes on screen (`NSWindow.animationBehavior`, read when it is ordered in): AppKit's
    /// document-window zoom only for a window the person opens now, and only when movement animates; a window a
    /// launch restores shows in place in its first frame, with no animation at all (REOPEN-F2).
    public func windowOpenBehavior(restoring: Bool) -> NSWindow.AnimationBehavior {
        !restoring && animatesMovement ? .documentWindow : .none
    }
}

extension MotionGate {
    /// See ``MotionPolicy/windowOpenBehavior(restoring:)``, with this gate's live policy.
    @MainActor public func windowOpenBehavior(restoring: Bool) -> NSWindow.AnimationBehavior {
        policy.windowOpenBehavior(restoring: restoring)
    }
}
