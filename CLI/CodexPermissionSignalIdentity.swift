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

    func correlatedToUniqueActiveToolStart(
        in startedIdentities: [Self],
        excluding resolvedIdentities: [Self]
    ) -> Self {
        guard requestID == nil else { return self }
        let active = startedIdentities.filter { candidate in
            candidate.isScoped &&
                (turnID == nil || candidate.turnID == turnID) &&
                !resolvedIdentities.contains(where: { $0.exactlyMatches(candidate) })
        }
        return active.count == 1 ? active[0] : self
    }
}
