import AppKit
public import CmuxNextDesignTokens

/// VoiceOver's button for one agent cursor tag (`AgentCursorCarrierView`).
/// AppKit calls accessibility on the main thread, but `NSAccessibilityElement`
/// is not main-actor isolated, so the press checks the thread and then enters
/// the main actor with `assumeIsolated`.
nonisolated final class AgentCursorTagElement: NSAccessibilityElement {
    /// Runs on the main actor only (the press checks the thread).
    private let onPress: @MainActor @Sendable () -> Void

    /// - Parameters:
    ///   - tag: The tag.
    ///   - frame: The tag's frame in the parent's (y-up) coordinates.
    ///   - parent: The cursor carrier.
    ///   - press: What a VoiceOver press does.
    init(_ tag: AgentCursorTagTarget, frame: NSRect, parent: NSView, press: @escaping @MainActor @Sendable () -> Void) {
        onPress = press
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(tag.accessibilityLabel ?? tag.label)
        setAccessibilityHelp(tag.help)
        setAccessibilityParent(parent)
        setAccessibilityFrameInParentSpace(frame)
    }

    /// AXEnabled: CuaDriver (0.32.0) indexes an NSAccessibilityElement, so a client can press it, only when it
    /// answers AXEnabled, though AppKit lists its AXPress either way (goal agent-shortcut-found, repro on
    /// a fleet Mac 2026-11-26: the same link with this override indexed, without it not).
    override func isAccessibilityEnabled() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        guard Thread.isMainThread else { return false }
        let press = onPress
        MainActor.assumeIsolated { press() } // main-proof: guarded by Thread.isMainThread above
        return true
    }
}
