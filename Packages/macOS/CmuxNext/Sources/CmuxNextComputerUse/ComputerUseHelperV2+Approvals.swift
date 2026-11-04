// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// App approvals on a worker's host link (docs/computer-use-approvals.md): the link's approval
/// lines go to ``ComputerUseHelperV2/approvals``, and its answers and the saved list go back on
/// the link in order.
extension ComputerUseHelperV2 {
    /// One link's approval wiring: where its questions go, and its end.
    nonisolated struct ApprovalAttachment: Sendable {
        let receive: @Sendable (ComputerUseApprovalWire.Incoming) -> Void
        let detach: @Sendable () async -> Void
    }

    /// Attaches `link` to the broker (nil without one: every question is refused on the link).
    func attachApprovals(to link: ComputerUseHelperV2HostLink) -> ApprovalAttachment? {
        guard let broker = approvals else { return nil }
        // A link carries one answer per question plus list updates: 1024 lines is far past any burst.
        let (outbox, sink) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(1024))
        let id = broker.attach(sink)
        // task-owner: drains this link's outbox in order; it ends when the broker detaches the link.
        let writer = Task.detached(priority: .userInitiated) {
            for await line in outbox { await link.send(line) }
        }
        return ApprovalAttachment(receive: { [weak broker] incoming in
            // task-owner: one main-actor hop per approval line; the broker answers on the outbox.
            Task { @MainActor in broker?.receive(incoming, link: id) }
        }, detach: { [weak broker] in
            await MainActor.run { broker?.detach(id) }
            writer.cancel()
        })
    }

    /// `computerUse.mode` changed: a running worker never changes mode, so stop its channel and
    /// start a new one, which starts in the new mode.
    /// A start still in progress checks the mode again once it runs (``configuredMode``).
    public func restartForModeChange() async {
        guard case .running = state, configuredMode != permissionMode() else { return }
        let expected = generation
        await stop()
        // Computer Use turned off (or started again) meanwhile: that apply decides, not this one.
        guard generation == expected else { return }
        await apply(enabled: true)
    }

    /// Whether this app's state as text (`computer_use.status`'s `worker`).
    public var stateName: String {
        switch state {
        case .off: "off"
        case .unavailable: "unavailable"
        case .running: "running"
        }
    }
}
