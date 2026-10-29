import AppKit
import CmuxNextDesign

extension WorkspaceRowView {
    /// Keep the tab disclosure beside the visible name. The trailing actions retain their slots,
    /// so a short name never leaves a sidebar-width gap before its caret.
    func layoutDisclosureBesideTitle(before actionStart: CGFloat, maximumX: CGFloat) {
        guard disclosure != nil, disclosure != .empty, !isShowingPlaceholder else { return }
        let gap = Metrics.space1
        let control = SidebarStyle.controlSize
        // Reserve hover controls even at rest: entering the row must not move the click target.
        let limit = min(maximumX, actionStart - gap - control)
        let width = max(0, limit - title.frame.minX - gap)
        title.frame.size.width = min(title.intrinsicContentSize.width, width)
        disclosureButton.frame.origin.x = title.frame.maxX + gap
    }
}
