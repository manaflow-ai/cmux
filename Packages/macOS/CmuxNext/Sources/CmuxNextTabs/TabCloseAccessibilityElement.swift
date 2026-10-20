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

    override func accessibilityPerformPress() -> Bool {
        (accessibilityParent() as? TabAccessibilityElement)?.performClose() ?? false
    }
}
