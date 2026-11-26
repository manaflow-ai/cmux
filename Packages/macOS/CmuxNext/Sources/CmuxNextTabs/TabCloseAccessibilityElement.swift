import AppKit

/// The x of a layer-drawn tab as a pressable child of its ``TabAccessibilityElement``, present
/// on every closable tab wide enough for it (it draws on hover). Computer-use agents and VoiceOver find it by
/// its identifier (`cmux.tabs.tab.<id>.close`) and press it with AXPress; the press closes the tab
/// through its parent's close handler, the same one as the tab's Close Tab custom action.
nonisolated final class TabCloseAccessibilityElement: NSAccessibilityElement {
    override init() {
        super.init()
        setAccessibilityRole(.button)
    }

    /// AXEnabled: CuaDriver (0.32.0) indexes an NSAccessibilityElement, so a client can press it, only when it
    /// answers AXEnabled, though AppKit lists its AXPress either way (goal agent-shortcut-found, repro on
    /// air-blue 2026-11-26: the same link with this override indexed, without it not).
    override func isAccessibilityEnabled() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        (accessibilityParent() as? TabAccessibilityElement)?.performClose() ?? false
    }
}
