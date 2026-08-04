public import CmuxAgentReplica

/// Renderable payload for one transcript row.
public enum TranscriptRowKind: Hashable, Sendable {
    /// Agent-authored prose.
    case proseAgent(text: String, grouping: TranscriptProseGrouping)
    /// User-authored prose.
    case proseUser(
        text: String,
        ticketState: SendTicketState?,
        grouping: TranscriptProseGrouping,
        attachmentCount: Int = 0,
        hasImage: Bool = false
    )
    /// A transcript status event.
    case status(code: StatusCode, detail: String?)
    /// A display date separator.
    case dateHeader(dayKey: String)
    /// The oldest-history boundary marker.
    case boundary
    /// A gap in the retained entry window.
    case hole(range: EntryRange)
    /// A local send waiting for transcript confirmation.
    case pendingTicket(SendTicket)
    /// An active question or permission request with ordered choices.
    case pendingAsk(PendingAsk)
    /// The single live streaming tail preview.
    case streaming(textTail: String)
    /// Compact display for known rich activity kinds not expanded in this slice.
    case genericActivity(TranscriptGenericActivity)
    /// Folded completed activity for one turn.
    case activitySummary(TranscriptActivitySummary)
    /// One visible live activity item.
    case activityItem(TranscriptActivityItem)
    /// Fail-open display for an unrecognized payload.
    case unsupported(rawKind: String, summary: String)
}
