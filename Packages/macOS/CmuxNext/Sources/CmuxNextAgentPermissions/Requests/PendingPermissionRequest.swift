/// A request the card shows or will show.
public nonisolated struct PendingPermissionRequest: Sendable, Equatable, Identifiable {
    /// Where the card is with this request.
    public enum Phase: String, Sendable, Equatable {
        /// The card asks: who, why, what the person asked; Deny or Continue.
        case asking
        /// The person pressed Continue: System Settings (or the macOS
        /// prompt) is open and the card guides; it waits for the grant.
        case guiding
    }

    /// `perm_…`, the id the agent gets back.
    public let id: String
    public let request: PermissionRequest
    public let reasonCheck: PermissionReasonCheck.Verdict
    public internal(set) var phase: Phase
    /// The grant the guide works on now (computer use asks for two in turn).
    public internal(set) var guidingGrant: PermissionKind?
    /// How many agent calls this one card answers (joined duplicates).
    public internal(set) var callers: Int

    init(id: String, request: PermissionRequest) {
        self.id = id
        self.request = request
        reasonCheck = request.reasonCheck.verdict
        phase = .asking
        guidingGrant = nil
        callers = 1
    }
}
