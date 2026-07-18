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
        actionGate: TerminalFrontendAccessibilityLinkActionGate
    ) {
        self.actionGate = actionGate
        super.init()
        setAccessibilityRole(.link)
        setAccessibilityLabel(label)
        setAccessibilityValue(link.target)
        setAccessibilityIdentifier(link.id)
        setAccessibilityParent(parent)
        setAccessibilityFrameInParentSpace(frameInParentSpace)
    }

    override func accessibilityPerformPress() -> Bool {
        actionGate.perform()
    }
}
