/// One agent's request for a grant, before cmux shows it.
public nonisolated struct PermissionRequest: Sendable, Equatable {
    /// The grant.
    public var kind: PermissionKind
    /// Why the agent needs it, in the agent's words (shown quoted).
    public var reason: String
    /// The person's message this request belongs to, when the agent names it.
    public var prompt: String?
    /// Who asks.
    public var requester: PermissionRequester
    /// The app an `automation` request wants to control (bundle id).
    public var target: String?

    public init(kind: PermissionKind, reason: String, prompt: String? = nil, requester: PermissionRequester, target: String? = nil) {
        self.kind = kind
        self.reason = reason
        self.prompt = prompt
        self.requester = requester
        self.target = target
    }

    /// The reason check for this request.
    public var reasonCheck: PermissionReasonCheck {
        PermissionReasonCheck(kind: kind, reason: reason, prompt: prompt)
    }

    /// Whether `other` asks for the same thing from the same agent (one card answers both).
    func joins(_ other: PermissionRequest) -> Bool {
        kind == other.kind && target == other.target && requester.agentID != nil && requester.agentID == other.requester.agentID
    }
}
