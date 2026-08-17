import AppKit

/// Accessibility proxy for one actionable link range in a sidebar row text view.
@MainActor
final class SidebarRowTextAccessibilityLink: NSAccessibilityElement {
    /// Character range represented by this element in the owner's attributed string.
    let characterRange: NSRange
    /// Validated HTTP(S) destination activated by this element.
    let url: URL
    /// Visible text used to identify equivalent proxies across row repaints.
    let label: String
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
        self.label = label
        super.init()
        setAccessibilityParent(owner)
        setAccessibilityRole(.link)
        setAccessibilityLabel(label)
        setAccessibilityURL(url)
    }

    /// Routes assistive-technology activation through the row's shared link action.
    nonisolated override func accessibilityPerformPress() -> Bool {
        // AppKit invokes synchronous accessibility callbacks on its UI
        // executor, but this Objective-C override imports as nonisolated.
        MainActor.assumeIsolated {
            owner?.openAccessibilityLink(url, characterRange: characterRange) ?? false
        }
    }

    /// Resolves geometry only when an accessibility client asks for it, so
    /// ordinary sidebar layout does not instantiate a TextKit stack per link.
    nonisolated override func accessibilityFrameInParentSpace() -> NSRect {
        MainActor.assumeIsolated {
            owner?.accessibilityFrame(forLinkRange: characterRange) ?? .zero
        }
    }

    /// Detaches a proxy that no longer represents the owner's current text.
    func invalidate() {
        guard owner != nil else { return }
        NSAccessibility.post(element: self, notification: .uiElementDestroyed)
        owner = nil
        setAccessibilityParent(nil)
    }
}
