import Foundation

/// What Retry does for a chat whose Move to Cloud stopped (``CloudMove``), by the chat's tab
/// on this Mac. Both the toast's Retry and running the action again on that tab read it, so a
/// move is never redone after it committed and an unresolved move is finished on its machine.
@MainActor
final class CloudMoveRetries {
    enum Retry: Equatable {
        /// The chat may not have moved: run the move again, to this machine.
        case move(machineID: String)
        /// The chat moved: only open its tab on the machine.
        case show(Shown)
        /// Bring Back Local only: this Mac's guard refused the machine's chat for a policy or mode
        /// that doesn't ask. Run the move again on this machine, narrowing the chat there to an
        /// asking policy and mode first ("Ask first, then bring back", cx-rppd.10).
        case askFirst(machineID: String)
        /// The machine's cmux-tui is too old for the move (`machine_outdated`, cx-rppd.13): its toast
        /// offers "Update Machine" (``CloudMachineUpdate``), which updates the machine, then runs the
        /// move again on it. Running the action again any other way only runs the move again there.
        case update(machineID: String)
    }

    /// A moved chat whose tab on the machine didn't open yet.
    struct Shown: Equatable {
        /// The chat's session on the machine.
        var session: String
        var harness: String?
        var machineID: String
        /// The chat's folder on the machine (the terminal's too).
        var folder: String
        /// The workspace name the chat had on this Mac.
        var name: String?
        /// The move's id: makes the tab's creation idempotent.
        var key: String
        /// For a chat Bring Back Local moved here: its ledger entry's machine tab host and session,
        /// forgotten once the tab opened (``CloudMovedChats``).
        var host: String?
        var movedSession: String?
    }

    private var pending: [String: Retry] = [:]

    subscript(tab: String) -> Retry? {
        get { pending[tab] }
        set { pending[tab] = newValue }
    }
}

extension CloudMoveRetries.Retry {
    /// The machine a rerun goes to; none for a move that committed.
    var machineID: String? {
        switch self {
        case .move(let machineID), .askFirst(let machineID), .update(let machineID): machineID
        case .show: nil
        }
    }

    /// This Retry for a machine whose cmux-tui is too old: "Update Machine" on its machine.
    var updating: Self {
        guard let machineID else { return self }
        return .update(machineID: machineID)
    }
}
