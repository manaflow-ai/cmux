internal import AppKit
internal import CmuxTerminalDomain

/// Revision-bound AX child for one daemon-projected OSC 8 link.
@MainActor
final class TerminalFrontendAccessibilityLinkElement: NSAccessibilityElement {
    private weak var bridge: TerminalFrontendAccessibilityBridge?
    let link: TerminalAccessibilityLink
    let snapshot: TerminalAccessibilitySnapshot

    init(
        bridge: TerminalFrontendAccessibilityBridge,
        link: TerminalAccessibilityLink,
        snapshot: TerminalAccessibilitySnapshot
    ) {
        self.bridge = bridge
        self.link = link
        self.snapshot = snapshot
        super.init()
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .link }

    override func accessibilityLabel() -> String? {
        guard let text = bridge?.string(for: link.utf16Range, snapshot: snapshot),
              !text.isEmpty else { return link.target }
        return text
    }

    override func accessibilityValue() -> Any? { link.target }

    override func accessibilityIdentifier() -> String? { link.id }

    override func accessibilityParent() -> Any? { bridge?.owner }

    override func accessibilityFrame() -> NSRect {
        bridge?.frame(for: link.utf16Range, snapshot: snapshot) ?? .zero
    }

    override func accessibilityPerformPress() -> Bool {
        bridge?.activate(link: link, snapshot: snapshot) ?? false
    }
}
