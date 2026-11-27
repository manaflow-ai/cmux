import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// A pane's "Computer use can act as me" pill (``AgentPaneActAsMeBadge``), made when the grant is on and never
/// for a page while it is off (the default).
///
/// The pill's glass surface, stack and button were about 5 ms of the main-thread build of EVERY page, a New Tab
/// spare's refill too, for a view that stayed hidden (CMD-T BUDGET 3, cause (c), 2026-11-10). Until the grant is
/// on, this follows it with one observation task (the one the pill had), which ends when it made the pill; from
/// then on the pill follows the grant itself.
///
/// ```swift
/// pane.actAsMePill.follow(grant, in: pane)
/// ```
@MainActor
final class AgentPaneActAsMePill {
    /// The pill, once the grant was on in this pane's life.
    private(set) var badge: AgentPaneActAsMeBadge?
    private var wait: Task<Void, Never>?

    nonisolated init() {}

    /// Makes the pill at `pane`'s top right when `grant` is on: in this call, or the first time the grant turns
    /// on. A second call does nothing.
    func follow(_ grant: AgentPaneActAsMe, in pane: AgentPaneView) {
        guard badge == nil, wait == nil else { return }
        if grant.isOn { return make(grant, in: pane) }
        // task-owner: this pill's `wait`, cancelled in stop() with the pane; it ends when it made the pill
        wait = Task { [weak self, weak pane] in
            for await on in ObservationStream({ [grant] in grant.isOn }) where on {
                guard let self, let pane, !Task.isCancelled else { return }
                self.wait = nil
                return self.make(grant, in: pane)
            }
        }
    }

    private func make(_ grant: AgentPaneActAsMe, in pane: AgentPaneView) {
        guard badge == nil else { return }
        let made = AgentPaneActAsMeBadge(grant: grant)
        pane.addSubview(made, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            made.topAnchor.constraint(equalTo: pane.topAnchor, constant: AgentPaneView.actAsMeBadgeTop),
            made.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -Metrics.space2),
        ])
        badge = made
        made.onFrameChange = { [weak pane] in pane?.applyNativeRects() }
        pane.applyNativeRects()
    }

    /// The pane's teardown: ends the wait and the pill's own following.
    func stop() {
        wait?.cancel()
        wait = nil
        badge?.stop()
    }
}
