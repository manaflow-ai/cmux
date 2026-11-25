import AppKit
import CmuxNextDesign

extension AgentPaneView {
    /// Shows the "Computer use can act as me" indicator at the pane's top right, under the chat's header
    /// row, while `grant` is on (``AgentPaneActAsMeBadge``); nil shows none. The pill is made when the grant
    /// is on, not for a page while it is off (``AgentPaneActAsMePill``).
    func showActAsMe(_ grant: AgentPaneActAsMe?) {
        if let grant { actAsMePill.follow(grant, in: self) }
    }

    /// Below the page's header row (its title and tab tools), so the pill covers none of its controls.
    static let actAsMeBadgeTop: CGFloat = Metrics.space6 + Metrics.space3
}
