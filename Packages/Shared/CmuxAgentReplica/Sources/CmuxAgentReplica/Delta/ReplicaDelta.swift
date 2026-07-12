import Foundation

/// Describes one typed replicated-state mutation.
public enum ReplicaDelta: Codable, Hashable, Sendable {
    /// Upserts a session snapshot.
    case sessionUpserted(AgentSessionSnapshot)
    /// Removes a session when the removal version wins.
    case sessionRemoved(id: AgentSessionID, version: EntityVersion)
    /// Appends contiguous entries for one journal.
    case entriesAppended(journalID: JournalID, entries: [EntrySnapshot])
    /// Replaces one already-loaded entry.
    case entryReplaced(EntrySnapshot)
    /// Rotates a conversation to a new journal and advertised tail.
    case journalReset(sessionID: AgentSessionID, newJournal: JournalID, tailSeq: EntrySeq)
    /// Changes one send ticket.
    case sendTicketChanged(SendTicket)
    /// Changes one pending ask.
    case askChanged(PendingAsk)
    /// Preserves an unknown mutation kind for fail-open decoding.
    case unknown(kind: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case snapshot
        case id
        case version
        case journalID
        case entries
        case entry
        case sessionID
        case newJournal
        case tailSeq
        case ticket
        case ask
    }

    /// Decodes a fail-open replicated mutation.
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "sessionUpserted":
            self = .sessionUpserted(try container.decode(AgentSessionSnapshot.self, forKey: .snapshot))
        case "sessionRemoved":
            self = .sessionRemoved(
                id: try container.decode(AgentSessionID.self, forKey: .id),
                version: try container.decode(EntityVersion.self, forKey: .version)
            )
        case "entriesAppended":
            self = .entriesAppended(
                journalID: try container.decode(JournalID.self, forKey: .journalID),
                entries: try container.decode([EntrySnapshot].self, forKey: .entries)
            )
        case "entryReplaced":
            self = .entryReplaced(try container.decode(EntrySnapshot.self, forKey: .entry))
        case "journalReset":
            self = .journalReset(
                sessionID: try container.decode(AgentSessionID.self, forKey: .sessionID),
                newJournal: try container.decode(JournalID.self, forKey: .newJournal),
                tailSeq: try container.decode(EntrySeq.self, forKey: .tailSeq)
            )
        case "sendTicketChanged":
            self = .sendTicketChanged(try container.decode(SendTicket.self, forKey: .ticket))
        case "askChanged":
            self = .askChanged(try container.decode(PendingAsk.self, forKey: .ask))
        default:
            self = .unknown(kind: kind)
        }
    }

    /// Encodes a replicated mutation.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessionUpserted(let snapshot):
            try container.encode("sessionUpserted", forKey: .kind)
            try container.encode(snapshot, forKey: .snapshot)
        case .sessionRemoved(let id, let version):
            try container.encode("sessionRemoved", forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(version, forKey: .version)
        case .entriesAppended(let journalID, let entries):
            try container.encode("entriesAppended", forKey: .kind)
            try container.encode(journalID, forKey: .journalID)
            try container.encode(entries, forKey: .entries)
        case .entryReplaced(let entry):
            try container.encode("entryReplaced", forKey: .kind)
            try container.encode(entry, forKey: .entry)
        case .journalReset(let sessionID, let newJournal, let tailSeq):
            try container.encode("journalReset", forKey: .kind)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(newJournal, forKey: .newJournal)
            try container.encode(tailSeq, forKey: .tailSeq)
        case .sendTicketChanged(let ticket):
            try container.encode("sendTicketChanged", forKey: .kind)
            try container.encode(ticket, forKey: .ticket)
        case .askChanged(let ask):
            try container.encode("askChanged", forKey: .kind)
            try container.encode(ask, forKey: .ask)
        case .unknown(let kind):
            try container.encode(kind, forKey: .kind)
        }
    }
}
