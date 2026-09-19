import AppKit
import CmuxSidebar

/// A native tooltip target that does not select or focus a workspace on hover.
@MainActor
final class SidebarRowPullRequestCheckIconView: NSImageView {
    func configure(checks: SidebarPullRequestChecks?, fallback: NSColor, pointSize: CGFloat) {
        isHidden = checks == nil
        guard let checks else {
            image = nil
            toolTip = nil
            setAccessibilityLabel(nil)
            return
        }
        let display = SidebarPullRequestChecksDisplay(checks: checks)
        image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: display.iconName, pointSize: pointSize, weight: .semibold
        )
        contentTintColor = display.tint ?? fallback
        imageScaling = .scaleProportionallyDown
        toolTip = display.tooltip
        setAccessibilityElement(true)
        setAccessibilityLabel(display.tooltip)
        setAccessibilityIdentifier("SidebarPullRequestChecks")
    }
}
