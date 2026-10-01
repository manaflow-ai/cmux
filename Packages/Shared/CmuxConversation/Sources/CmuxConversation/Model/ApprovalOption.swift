/// One answer the user can give to an ``ApprovalRequest``.
public struct ApprovalOption: Hashable, Sendable, Identifiable {
    /// The backend's identifier for the answer.
    public let id: String
    /// The label to show.
    public var label: String
    /// `allow_once`, `allow_always`, `reject_once`, `reject_always`, or a
    /// backend-specific kind; drives styling (approve vs reject).
    public var kind: String

    /// Creates an option.
    /// - Parameters:
    ///   - id: The backend's identifier for the answer.
    ///   - label: The label to show.
    ///   - kind: The answer's kind.
    public init(id: String, label: String, kind: String) {
        self.id = id
        self.label = label
        self.kind = kind
    }

    /// Whether choosing it lets the agent proceed.
    public var isApproval: Bool { kind.hasPrefix("allow") }
}
