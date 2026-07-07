#if os(iOS)
import UIKit

final class ChatTranscriptScrollToBottomFlight {
    private struct Flight {
        var legsRemaining: Int
    }

    private var flight: Flight?
    /// Hard bound so estimated-height drift cannot loop forever.
    private let maxFlightLegs = 8
    /// Distance from the bottom used for a far-away pre-position before landing.
    private let animatedRunwayInViewports: CGFloat = 1.5

    var isActive: Bool {
        flight != nil
    }

    func start(
        in tableView: ChatTranscriptUITableView,
        setAtBottom: (Bool) -> Void
    ) {
        flight = Flight(legsRemaining: maxFlightLegs)
        tableView.layoutIfNeeded()

        let runway = tableView.bounds.height * animatedRunwayInViewports
        let target = tableView.chatTranscriptMaxOffsetY
        if runway > 0, target - tableView.contentOffset.y > runway {
            tableView.setContentOffset(
                CGPoint(
                    x: tableView.contentOffset.x,
                    y: tableView.chatTranscriptClampedOffsetY(target - runway)
                ),
                animated: false
            )
            tableView.layoutIfNeeded()
        }

        setAtBottom(true)
        performLeg(in: tableView, setAtBottom: setAtBottom, updateBottomState: { _ in })
    }

    func continueAfterContentChange(
        in tableView: ChatTranscriptUITableView,
        setAtBottom: (Bool) -> Void,
        updateBottomState: (UITableView) -> Void
    ) {
        performLeg(in: tableView, setAtBottom: setAtBottom, updateBottomState: updateBottomState)
    }

    func didEndScrollingAnimation(
        in tableView: ChatTranscriptUITableView,
        setAtBottom: (Bool) -> Void,
        updateBottomState: (UITableView) -> Void
    ) {
        performLeg(in: tableView, setAtBottom: setAtBottom, updateBottomState: updateBottomState)
    }

    func handleLayoutChange(
        in tableView: ChatTranscriptUITableView,
        distanceFromBottom: CGFloat,
        setAtBottom: (Bool) -> Void,
        updateBottomState: (UITableView) -> Void
    ) {
        if distanceFromBottom <= 1 {
            finish(in: tableView, setAtBottom: setAtBottom, updateBottomState: updateBottomState)
            return
        }
        updateBottomState(tableView)
    }

    func cancel() {
        flight = nil
    }

    private func performLeg(
        in tableView: ChatTranscriptUITableView,
        setAtBottom: (Bool) -> Void,
        updateBottomState: (UITableView) -> Void
    ) {
        guard flight != nil else { return }
        tableView.layoutIfNeeded()

        let target = tableView.chatTranscriptMaxOffsetY
        let delta = target - tableView.contentOffset.y
        if abs(delta) <= 1 {
            finish(in: tableView, setAtBottom: setAtBottom, updateBottomState: updateBottomState)
            return
        }

        guard let currentFlight = flight, currentFlight.legsRemaining > 0 else {
            tableView.setContentOffset(
                CGPoint(x: tableView.contentOffset.x, y: target),
                animated: false
            )
            finish(in: tableView, setAtBottom: setAtBottom, updateBottomState: updateBottomState)
            return
        }

        flight = Flight(legsRemaining: currentFlight.legsRemaining - 1)
        tableView.setContentOffset(CGPoint(x: tableView.contentOffset.x, y: target), animated: true)
    }

    private func finish(
        in tableView: ChatTranscriptUITableView,
        setAtBottom: (Bool) -> Void,
        updateBottomState: (UITableView) -> Void
    ) {
        flight = nil
        tableView.recordCurrentViewport()
        setAtBottom(true)
        updateBottomState(tableView)
    }
}

#endif
