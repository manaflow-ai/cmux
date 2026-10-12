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
