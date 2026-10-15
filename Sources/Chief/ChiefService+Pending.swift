import CmuxHomeCore
import Foundation

/// What a running turn is doing for the working status line above the field:
/// when it started and whether it waits on the user's approval.
extension ChiefService {
    /// When `conversation`'s running turn started, nil while it is idle.
    /// Observation-tracked through ``workingConversations``.
    func turnStart(_ conversation: ConversationID) -> ContinuousClock.Instant? {
        guard workingConversations.contains(conversation) else { return nil }
        return turnStarts[conversation]
    }

    /// Whether `conversation`'s running turn waits on an approval the user
    /// has not answered (an `.approval` part with no decision).
    ///
    /// Observation-tracked through the store's transcript version for the
    /// conversation, so it re-reads only when that conversation changes.
    /// Idle conversations answer false without reading the transcript.
    func hasPendingApproval(_ conversation: ConversationID) -> Bool {
        guard workingConversations.contains(conversation), let store = storeIfStarted else { return false }
        _ = store.transcriptVersion[conversation]
        // An approval belongs to the running turn: it sits among the newest rows.
        for item in store.transcript(for: conversation).suffix(Self.pendingApprovalScanLimit).reversed() {
            for part in item.parts {
                if case .approval(let ref) = part, ref.decided == nil { return true }
            }
        }
        return false
    }

    /// How many of the newest rows hold the running turn's approval.
    private static let pendingApprovalScanLimit = 24
}
