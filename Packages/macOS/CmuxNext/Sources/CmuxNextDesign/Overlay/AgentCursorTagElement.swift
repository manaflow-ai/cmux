import AppKit

/// VoiceOver's button for one agent cursor tag (`AgentCursorCarrierView`).
final class AgentCursorTagElement: NSAccessibilityElement {
    let id: String
    private weak var carrier: AgentCursorCarrierView?

    init(_ tag: AgentCursorTagTarget, carrier: AgentCursorCarrierView) {
        id = tag.id
        self.carrier = carrier
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(tag.accessibilityLabel ?? tag.label)
        setAccessibilityHelp(tag.help)
        setAccessibilityParent(carrier)
        setAccessibilityFrameInParentSpace(carrier.localRect(tag.frame))
    }

    override func accessibilityPerformPress() -> Bool {
        guard let carrier, let tags = carrier.tags else { return false }
        tags.pressAgentCursorTag(id)
        return true
    }
}
