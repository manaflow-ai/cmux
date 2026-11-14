public import CmuxNextCloud

/// What a failed Move to Cloud, Move to another machine or Bring Back Local answer means, in the
/// person's words, and what its Retry does (the App's `CloudMove`, `CloudStartChat`, `CloudBringBack`).
/// `CloudMoveFailure` is nonisolated (CmuxNextCloud); its texts are this target's main-actor strings,
/// and every caller is on the main actor, so these makers are too.
@MainActor
extension CloudMoveFailure {
    /// A failed copy's failure: an outdated machine's Retry updates it first.
    public static func syncing(_ answer: CloudMoveCLI.Answer, machine: String, retry: CloudMoveRetries.Retry) -> Self {
        if answer.errorCode == CloudMoveStrings.outdatedCode { return Self(message: CloudMoveStrings.outdatedMachine(machine), retry: retry.updating) }
        // Past the copy's limits (`copy.too_large`): another try fails the same way, so no Retry (the start then deletes its machine).
        if answer.errorCode == CloudMoveCLI.StartChatPreflightRefusal.code { return Self(message: CloudMoveStrings.syncFailed(machine, answer.error ?? "")) }
        return Self(message: CloudMoveStrings.syncFailed(machine, answer.error ?? answer.errorCode ?? ""), retry: retry)
    }

    /// The failure of a `cmux link agent move` answer, in plain words. `retry`
    /// runs the move again on its machine; a garbage answer (a crash) may come
    /// after the commit, so it is unresolved, never failed.
    public static func moving(_ answer: CloudMoveCLI.Answer, machine: String, retry: CloudMoveRetries.Retry) -> Self {
        switch answer.errorCode {
        case "move_unresolved", CloudMoveCLI.badAnswer: Self(message: CloudMoveStrings.unresolved, retry: retry)
        case "move_in_progress": Self(message: CloudMoveStrings.inProgress, retry: retry)
        case "agent_session.team_vm_blocked": Self(message: CloudMoveStrings.teamMachine(machine))
        case "agent_session.host_unverified": Self(message: CloudMoveStrings.unknownMachine(machine))
        // This Mac's own daemon (the source) is never the machine to update.
        case CloudMoveStrings.outdatedCode where answer.side != "source":
            Self(message: CloudMoveStrings.outdatedMachine(machine), retry: retry.updating)
        case "source_unreachable", "target_unreachable": Self(message: CloudMoveStrings.unreachable(machine), retry: retry)
        // A machine with no acpmux up yet (cmux#31198), too busy or too slow gave the chat back: the same move may work again.
        default: Self(message: CloudMoveStrings.moveFailed(answer.error ?? answer.errorCode ?? ""), retry: answer.errorCode.map { ["agent_transfer.unavailable", "agent_transfer.limit", "agent_transfer.timeout"].contains($0) } == true ? retry : nil)
        }
    }

    /// The failure of a `cmux link agent move` answer, in plain words. This Mac's guard refuses a
    /// chat that approves on its own (`transfer.policy`), runs in a mode that doesn't ask
    /// (`transfer.mode`), or runs an agent it can't guard (`transfer.family`); the chat stays on
    /// the machine, unchanged, and the first two offer "Ask first, then bring back", which narrows
    /// the chat on the machine and moves it again. When that run (`askedFirst`) is refused too, the
    /// chat can't be narrowed there (no asking mode it offers, say): the person changes it in the
    /// chat, then Retry.
    public static func bringingBack(_ answer: CloudMoveCLI.Answer, machine: String, retry: CloudMoveRetries.Retry,
                                    askedFirst: Bool = false) -> Self {
        let detail = answer.error ?? ""
        var askFirst = retry
        if case .move(let machineID) = retry { askFirst = .askFirst(machineID: machineID) }
        if detail.contains("transfer.policy") {
            if askedFirst { return Self(message: CloudBringBackStrings.policyStillBlocks, retry: retry) }
            return Self(message: CloudBringBackStrings.policyBlocks, retry: askFirst)
        }
        if detail.contains("transfer.mode") {
            if askedFirst { return Self(message: CloudBringBackStrings.modeStillBlocks, retry: retry) }
            return Self(message: CloudBringBackStrings.modeBlocks, retry: askFirst)
        }
        if detail.contains("transfer.family") { return Self(message: CloudBringBackStrings.familyBlocks) }
        switch answer.errorCode {
        // The turn's last changes conflicted: the chat went back to the machine and goes on there.
        case "sync_conflict": return Self(message: CloudBringBackStrings.conflict(answer.conflicts), retry: retry)
        case "move_unresolved", CloudMoveCLI.badAnswer: return Self(message: CloudBringBackStrings.unresolved, retry: retry)
        case "move_in_progress": return Self(message: CloudMoveStrings.inProgress, retry: retry)
        case "source_unreachable", "target_unreachable": return Self(message: CloudMoveStrings.unreachable(machine), retry: retry)
        // This Mac's own daemon (the target) is never the machine to update.
        case CloudMoveStrings.outdatedCode where answer.side != "target":
            return Self(message: CloudBringBackStrings.outdatedMachine(machine), retry: retry.updating)
        default: return Self(message: CloudBringBackStrings.failed(answer.error ?? answer.errorCode ?? ""))
        }
    }
}
