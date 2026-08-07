import AppKit

/// Accessibility proxy for one actionable link range in a sidebar row text view.
@MainActor
final class SidebarRowTextAccessibilityLink: NSAccessibilityElement {
    /// Character range represented by this element in the owner's attributed string.
    let characterRange: NSRange
    /// Validated HTTP(S) destination activated by this element.
    let url: URL
    private weak var owner: SidebarRowTextView?

    /// Creates a link element parented to the row text view that owns its action.
    init(
        owner: SidebarRowTextView,
        characterRange: NSRange,
        label: String,
        url: URL
    ) {
        self.owner = owner
        self.characterRange = characterRange
        self.url = url
        super.init()
        setAccessibilityParent(owner)
        setAccessibilityRole(.link)
        setAccessibilityLabel(label)
        setAccessibilityURL(url)
    }

    /// Routes assistive-technology activation through the row's shared link action.
    override func accessibilityPerformPress() -> Bool {
        owner?.openLink(url) ?? false
    }

    /// Detaches a proxy that no longer represents the owner's current text.
    func invalidate() {
        owner = nil
        setAccessibilityParent(nil)
        setAccessibilityFrameInParentSpace(.zero)
    }
}
