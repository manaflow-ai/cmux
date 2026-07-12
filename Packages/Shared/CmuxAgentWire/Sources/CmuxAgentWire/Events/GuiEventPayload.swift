/// A typed, fail-open payload carried by ``GuiEventFrame``.
public enum GuiEventPayload: Hashable, Sendable {
    /// A session snapshot was upserted.
    case sessionUpserted(GuiSessionUpsertedEvent)
    /// A versioned session was removed.
    case sessionRemoved(GuiSessionRemovedEvent)
    /// Whole-value entries were appended.
    case entriesAppended(GuiEntriesAppendedEvent)
    /// One whole-value entry was replaced.
    case entryReplaced(GuiEntryReplacedEvent)
    /// A session rotated to a new journal.
    case journalReset(GuiJournalResetEvent)
    /// A send ticket changed state.
    case sendState(GuiSendStateEvent)
    /// A pending ask changed state.
    case askState(GuiAskStateEvent)
    /// An ephemeral streaming preview changed.
    case streamTick(GuiStreamTickEvent)
    /// An unknown or malformed future event kind preserved without failing the stream.
    case unknown(String)

    /// The open event-kind string carried on the wire.
    public var kind: String {
        switch self {
        case .sessionUpserted: "session_upserted"
        case .sessionRemoved: "session_removed"
        case .entriesAppended: "entries_appended"
        case .entryReplaced: "entry_replaced"
        case .journalReset: "journal_reset"
        case .sendState: "send_state"
        case .askState: "ask_state"
        case .streamTick: "stream_tick"
        case .unknown(let kind): kind
        }
    }
}
