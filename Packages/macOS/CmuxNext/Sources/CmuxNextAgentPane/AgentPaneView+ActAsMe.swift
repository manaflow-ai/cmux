import AppKit
import CmuxNextDesign

extension AgentPaneView {
    /// Shows the "Computer use can act as me" indicator at the pane's top right, under the chat's header
    /// row, while `grant` is on (``AgentPaneActAsMeBadge``); nil shows none.
    func showActAsMe(_ grant: AgentPaneActAsMe?) {
        guard let grant, actAsMeBadge == nil else { return }
        let badge = AgentPaneActAsMeBadge(grant: grant)
        addSubview(badge, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: topAnchor, constant: Self.actAsMeBadgeTop),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space2),
        ])
        actAsMeBadge = badge
        badge.onFrameChange = { [weak self] in self?.applyNativeRects() }
        applyNativeRects()
    }

    /// Below the page's header row (its title and tab tools), so the pill covers none of its controls.
    static let actAsMeBadgeTop: CGFloat = Metrics.space6 + Metrics.space3
}
