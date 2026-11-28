/// A mutation-maintained index from terminal surfaces to chat session IDs.
public struct ChatSessionSurfaceIndex<SessionID: Hashable & Sendable>: Sendable {
    private var sessionIDsBySurfaceID: [String: Set<SessionID>] = [:]

    /// Creates an empty surface index.
    public init() {}

    /// Reconciles one session's previous and current surface bindings.
    ///
    /// - Parameters:
    ///   - sessionID: Stable identity of the changed session.
    ///   - previousSurfaceID: Surface before the mutation, or `nil`.
    ///   - currentSurfaceID: Surface after the mutation, or `nil`.
    public mutating func update(
        sessionID: SessionID,
        previousSurfaceID: String?,
        currentSurfaceID: String?
    ) {
        if let previousSurfaceID, previousSurfaceID != currentSurfaceID {
            sessionIDsBySurfaceID[previousSurfaceID]?.remove(sessionID)
            if sessionIDsBySurfaceID[previousSurfaceID]?.isEmpty == true {
                sessionIDsBySurfaceID.removeValue(forKey: previousSurfaceID)
            }
        }
        if let currentSurfaceID {
            sessionIDsBySurfaceID[currentSurfaceID, default: []].insert(sessionID)
        }
    }

    /// Returns all sessions currently bound to a surface.
    ///
    /// - Parameter surfaceID: Terminal surface UUID string.
    /// - Returns: Session IDs associated with the surface.
    public func sessionIDs(surfaceID: String) -> Set<SessionID> {
        sessionIDsBySurfaceID[surfaceID] ?? []
    }

    /// Returns valid indexed sessions, rebuilding a missing surface entry from authoritative records.
    ///
    /// The full record dictionary is scanned only when the index has no valid
    /// entry for `surfaceID`. Any recovered bindings are retained so later
    /// lookups return directly from the index.
    ///
    /// - Parameters:
    ///   - surfaceID: Terminal surface UUID string.
    ///   - records: Authoritative records keyed by session identity.
    ///   - recordSurfaceID: Key path to each record's current surface binding.
    /// - Returns: Session IDs currently associated with the surface.
    public mutating func sessionIDs<Record: Sendable>(
        surfaceID: String,
        healingFrom records: [SessionID: Record],
        recordSurfaceID: KeyPath<Record, String?>
    ) -> Set<SessionID> {
        let indexed = sessionIDsBySurfaceID[surfaceID] ?? []
        var validIndexed: Set<SessionID> = []
        for sessionID in indexed {
            guard let record = records[sessionID],
                  record[keyPath: recordSurfaceID] == surfaceID else {
                update(
                    sessionID: sessionID,
                    previousSurfaceID: surfaceID,
                    currentSurfaceID: nil
                )
                continue
            }
            validIndexed.insert(sessionID)
        }
        guard validIndexed.isEmpty else { return validIndexed }

        var recovered: Set<SessionID> = []
        for (sessionID, record) in records
        where record[keyPath: recordSurfaceID] == surfaceID {
            recovered.insert(sessionID)
            update(
                sessionID: sessionID,
                previousSurfaceID: nil,
                currentSurfaceID: surfaceID
            )
        }
        return recovered
    }
}
