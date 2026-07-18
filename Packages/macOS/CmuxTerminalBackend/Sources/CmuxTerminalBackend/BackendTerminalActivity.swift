public import Foundation

/// The canonical cause of one terminal activity fact.
public enum BackendTerminalActivityKind: String, Codable, Equatable, Sendable {
    case notification
}

/// Notification severity retained without notification title or body content.
public enum BackendTerminalActivityLevel: String, Codable, Equatable, Sendable {
    case info
    case warning
    case error
}

/// The daemon's latest activity fact for one stable terminal UUID.
public struct BackendTerminalActivityFact: Codable, Equatable, Sendable {
    public let surfaceID: SurfaceID
    public let sequence: UInt64
    public let kind: BackendTerminalActivityKind
    public let notificationID: UInt64
    public let level: BackendTerminalActivityLevel

    public init(
        surfaceID: SurfaceID,
        sequence: UInt64,
        kind: BackendTerminalActivityKind,
        notificationID: UInt64,
        level: BackendTerminalActivityLevel
    ) {
        self.surfaceID = surfaceID
        self.sequence = sequence
        self.kind = kind
        self.notificationID = notificationID
        self.level = level
    }

    private enum CodingKeys: String, CodingKey {
        case surfaceID = "surface_uuid"
        case sequence
        case kind
        case notificationID = "notification"
        case level
    }
}

/// One stable reader's durable high-water mark for a terminal.
public struct BackendTerminalActivityReceipt: Codable, Equatable, Sendable {
    public let readerUUID: UUID
    public let surfaceID: SurfaceID
    public let seenSequence: UInt64

    public init(readerUUID: UUID, surfaceID: SurfaceID, seenSequence: UInt64) {
        self.readerUUID = readerUUID
        self.surfaceID = surfaceID
        self.seenSequence = seenSequence
    }

    private enum CodingKeys: String, CodingKey {
        case readerUUID = "reader_uuid"
        case surfaceID = "surface_uuid"
        case seenSequence = "seen_sequence"
    }
}

/// Canonical terminal activity and the requesting reader's durable receipts.
public struct BackendTerminalActivitySnapshot: Codable, Equatable, Sendable {
    public let readerUUID: UUID
    public let latestSequence: UInt64
    public let facts: [BackendTerminalActivityFact]
    public let receipts: [BackendTerminalActivityReceipt]

    public init(
        readerUUID: UUID,
        latestSequence: UInt64,
        facts: [BackendTerminalActivityFact],
        receipts: [BackendTerminalActivityReceipt]
    ) {
        self.readerUUID = readerUUID
        self.latestSequence = latestSequence
        self.facts = facts
        self.receipts = receipts
    }

    /// Returns whether this reader has not acknowledged the terminal's latest fact.
    public func isUnread(surfaceID: SurfaceID) -> Bool {
        guard let fact = facts.first(where: { $0.surfaceID == surfaceID }) else { return false }
        let seen = receipts.first(where: { $0.surfaceID == surfaceID })?.seenSequence ?? 0
        return fact.sequence > seen
    }

    private enum CodingKeys: String, CodingKey {
        case readerUUID = "reader_uuid"
        case latestSequence = "latest_sequence"
        case facts
        case receipts
    }
}

public extension BackendProtocolClient {
    /// Fetches canonical terminal activity for this connection's registered reader UUID.
    func terminalActivitySnapshot() async throws -> BackendTerminalActivitySnapshot {
        try await call(
            command: "terminal-activity-snapshot",
            as: BackendTerminalActivitySnapshot.self
        )
    }

    /// Durably acknowledges one observed activity sequence for this registered reader.
    func markTerminalSeen(
        surfaceID: SurfaceID,
        activitySequence: UInt64
    ) async throws -> BackendTerminalActivityReceipt {
        try await call(
            command: "mark-terminal-seen",
            parameters: [
                "surface_uuid": .string(surfaceID.description),
                "activity_sequence": .unsignedInteger(activitySequence),
            ],
            as: BackendTerminalActivityReceipt.self
        )
    }
}

public extension BackendServerEvent {
    /// Decodes one canonical terminal activity fact.
    func terminalActivityFact() throws -> BackendTerminalActivityFact {
        guard name == "terminal-activity" else {
            throw BackendProtocolError.malformedMessage
        }
        return try JSONDecoder().decode(
            BackendTerminalActivityFact.self,
            from: JSONEncoder().encode(self)
        )
    }

    /// Decodes one durable terminal activity receipt for the registered reader.
    func terminalActivityReceipt() throws -> BackendTerminalActivityReceipt {
        guard name == "terminal-activity-receipt" else {
            throw BackendProtocolError.malformedMessage
        }
        return try JSONDecoder().decode(
            BackendTerminalActivityReceipt.self,
            from: JSONEncoder().encode(self)
        )
    }
}

/// Validated local projection of the daemon's activity facts and one reader's receipts.
internal struct BackendTerminalActivityProjection: Sendable {
    private(set) var readerUUID: UUID?
    private(set) var latestSequence: UInt64 = 0
    private var facts: [SurfaceID: BackendTerminalActivityFact] = [:]
    private var receipts: [SurfaceID: BackendTerminalActivityReceipt] = [:]

    var isInstalled: Bool { readerUUID != nil }

    mutating func install(
        _ snapshot: BackendTerminalActivitySnapshot,
        expectedReaderUUID: UUID
    ) throws {
        guard !Self.isNil(expectedReaderUUID),
              snapshot.readerUUID == expectedReaderUUID,
              !Self.isNil(snapshot.readerUUID)
        else {
            throw BackendProtocolError.malformedMessage
        }

        var installedFacts: [SurfaceID: BackendTerminalActivityFact] = [:]
        var factSequences: Set<UInt64> = []
        for fact in snapshot.facts {
            guard !Self.isNil(fact.surfaceID.rawValue),
                  fact.sequence > 0,
                  fact.sequence <= snapshot.latestSequence,
                  fact.notificationID > 0,
                  installedFacts.updateValue(fact, forKey: fact.surfaceID) == nil,
                  factSequences.insert(fact.sequence).inserted
            else {
                throw BackendProtocolError.malformedMessage
            }
        }

        var installedReceipts: [SurfaceID: BackendTerminalActivityReceipt] = [:]
        for receipt in snapshot.receipts {
            guard receipt.readerUUID == expectedReaderUUID,
                  !Self.isNil(receipt.surfaceID.rawValue),
                  receipt.seenSequence > 0,
                  let fact = installedFacts[receipt.surfaceID],
                  receipt.seenSequence <= fact.sequence,
                  installedReceipts.updateValue(receipt, forKey: receipt.surfaceID) == nil
            else {
                throw BackendProtocolError.malformedMessage
            }
        }

        readerUUID = expectedReaderUUID
        latestSequence = snapshot.latestSequence
        facts = installedFacts
        receipts = installedReceipts
    }

    mutating func apply(_ fact: BackendTerminalActivityFact) throws -> Bool {
        guard isInstalled,
              !Self.isNil(fact.surfaceID.rawValue),
              fact.sequence > 0,
              fact.notificationID > 0
        else {
            throw BackendProtocolError.malformedMessage
        }
        // The subscribe-before-snapshot bootstrap can leave already-snapshotted
        // events queued. The persisted snapshot is authoritative for that prefix.
        if fact.sequence <= latestSequence { return false }
        guard latestSequence != UInt64.max, fact.sequence == latestSequence + 1 else {
            throw BackendProtocolError.malformedMessage
        }
        latestSequence = fact.sequence
        facts[fact.surfaceID] = fact
        return true
    }

    mutating func apply(_ receipt: BackendTerminalActivityReceipt) throws -> Bool {
        guard let readerUUID,
              receipt.readerUUID == readerUUID,
              !Self.isNil(receipt.surfaceID.rawValue),
              receipt.seenSequence > 0,
              let fact = facts[receipt.surfaceID],
              receipt.seenSequence <= fact.sequence
        else {
            throw BackendProtocolError.malformedMessage
        }
        if let existing = receipts[receipt.surfaceID],
           receipt.seenSequence <= existing.seenSequence {
            return false
        }
        receipts[receipt.surfaceID] = receipt
        return true
    }

    func snapshot(liveSurfaceIDs: Set<SurfaceID>? = nil) -> BackendTerminalActivitySnapshot? {
        guard let readerUUID else { return nil }
        let includedFacts = facts.values
            .filter { liveSurfaceIDs?.contains($0.surfaceID) ?? true }
            .sorted { lhs, rhs in
                if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
                return lhs.surfaceID.description < rhs.surfaceID.description
            }
        let includedSurfaceIDs = Set(includedFacts.map(\.surfaceID))
        let includedReceipts = receipts.values
            .filter { includedSurfaceIDs.contains($0.surfaceID) }
            .sorted { $0.surfaceID.description < $1.surfaceID.description }
        return BackendTerminalActivitySnapshot(
            readerUUID: readerUUID,
            latestSequence: latestSequence,
            facts: includedFacts,
            receipts: includedReceipts
        )
    }

    mutating func invalidate() {
        readerUUID = nil
        latestSequence = 0
        facts.removeAll(keepingCapacity: false)
        receipts.removeAll(keepingCapacity: false)
    }

    private static func isNil(_ identifier: UUID) -> Bool {
        identifier == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
}
