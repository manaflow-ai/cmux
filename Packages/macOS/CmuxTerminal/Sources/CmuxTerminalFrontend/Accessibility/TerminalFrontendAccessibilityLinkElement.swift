internal import AppKit
internal import CmuxTerminalDomain

/// Revision-bound AX child for one daemon-projected OSC 8 link.
final class TerminalFrontendAccessibilityLinkElement: NSAccessibilityElement {
    private let actionGate: TerminalFrontendAccessibilityLinkActionGate

    @MainActor
    init(
        parent: TerminalFrontendInteractionView,
        link: TerminalAccessibilityLink,
        label: String,
        frameInParentSpace: NSRect,
        action: @escaping @Sendable () -> Void
    ) {
        actionGate = TerminalFrontendAccessibilityLinkActionGate(action: action)
        super.init()
        setAccessibilityRole(.link)
        setAccessibilityLabel(label)
        setAccessibilityValue(link.target)
        setAccessibilityIdentifier(link.id)
        setAccessibilityParent(parent)
        accessibilityFrameInParentSpace = frameInParentSpace
    }

    override func accessibilityPerformPress() -> Bool {
        actionGate.perform()
    }

    func invalidate() {
        actionGate.invalidate()
    }
}
