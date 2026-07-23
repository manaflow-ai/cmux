/// The strongest request scope Codex exposed on a hook payload.
struct CodexPermissionSignalIdentity: Codable, Equatable, Sendable {
    let turnID: String?
    let requestID: String?

    var isScoped: Bool { turnID != nil || requestID != nil }

    func exactlyMatches(_ other: Self) -> Bool {
        guard isScoped, other.isScoped else { return false }
        if requestID != nil || other.requestID != nil {
            guard requestID == other.requestID else { return false }
            if let turnID, let otherTurnID = other.turnID {
                return turnID == otherTurnID
            }
            return true
        }
        return turnID == other.turnID
    }
}
