import AppKit
import CmuxNextCompat
import CmuxNextDesign

extension AgentPaneView {
    /// Shows the "Computer use can act as me" indicator at the pane's top right, under the chat's header
    /// row, while `grant` is on (``AgentPaneActAsMeBadge``); nil shows none.
    ///
    /// The pill is made when the grant is on, never for a page while it is off (the default): its glass
    /// surface, stack and button were about 5 ms of the main-thread build of EVERY page, a New Tab spare's
    /// refill too, for a view that stayed hidden (CMD-T BUDGET 3, cause (c), 2026-11-10). Until then the pane
    /// follows the grant with one observation task (the one the pill had), which ends when it made the pill;
    /// from then on the pill follows the grant itself.
    func showActAsMe(_ grant: AgentPaneActAsMe?) {
        guard let grant, actAsMeBadge == nil, actAsMeWait == nil else { return }
        if grant.isOn { return makeActAsMeBadge(grant) }
        // task-owner: the pane's `actAsMeWait`, cancelled in the pane's deinit; it ends when it made the pill
        actAsMeWait = Task { [weak self] in
            for await on in ObservationStream({ [grant] in grant.isOn }) where on {
                guard let self, !Task.isCancelled else { return }
                self.actAsMeWait = nil
                return self.makeActAsMeBadge(grant)
            }
        }
    }

    private func makeActAsMeBadge(_ grant: AgentPaneActAsMe) {
        guard actAsMeBadge == nil else { return }
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
