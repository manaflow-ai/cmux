public import Foundation

/// Tracks the single control-lane owner for each admitted mobile IROH session.
///
/// Claims are indexed in both directions so releasing one transport visits only
/// that owner's sessions instead of scanning every live session.
public struct MobileIrxControlLaneClaims: Sendable {
    private var ownerBySession: [String: UUID] = [:]
    private var sessionsByOwner: [UUID: Set<String>] = [:]

    /// Creates an empty claim registry.
    public init() {}

    /// Claims a session for an owner, or returns false when another owner holds it.
    public mutating func claim(sessionID: String, ownerID: UUID) -> Bool {
        if let existingOwner = ownerBySession[sessionID], existingOwner != ownerID {
            return false
        }
        ownerBySession[sessionID] = ownerID
        sessionsByOwner[ownerID, default: []].insert(sessionID)
        return true
    }

    /// Releases all sessions held by one transport owner.
    public mutating func release(ownerID: UUID) {
        guard let sessions = sessionsByOwner.removeValue(forKey: ownerID) else { return }
        for sessionID in sessions where ownerBySession[sessionID] == ownerID {
            ownerBySession.removeValue(forKey: sessionID)
        }
    }

    /// Clears every claim during runtime teardown or sign-out.
    public mutating func removeAll() {
        ownerBySession.removeAll()
        sessionsByOwner.removeAll()
    }
}
