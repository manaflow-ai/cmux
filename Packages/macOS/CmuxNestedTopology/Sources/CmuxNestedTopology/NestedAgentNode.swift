/// Immutable agent value owned by a provider pane.
public struct NestedAgentNode: Codable, Equatable, Sendable {
    /// Compound agent identity.
    public let id: NestedNodeID

    /// Provider-owned parent pane.
    public let paneID: NestedNodeID

    /// Optional provider session value preserved byte-for-byte on the wire.
    public let sessionID: String?

    /// Provider order among sibling agents.
    public let order: Int

    /// Optional display title with explicit authority.
    public let title: NestedNodeTitle?

    /// Normalized status with original provider value retained.
    public let status: NestedAgentStatus

    /// Creates a provider-owned agent value.
    ///
    /// - Parameters:
    ///   - id: Compound agent identity.
    ///   - paneID: Provider-owned parent pane.
    ///   - sessionID: Optional provider session value.
    ///   - order: Provider order among sibling agents.
    ///   - title: Optional display title.
    ///   - status: Normalized and raw provider status.
    public init(
        id: NestedNodeID,
        paneID: NestedNodeID,
        sessionID: String?,
        order: Int,
        title: NestedNodeTitle?,
        status: NestedAgentStatus
    ) {
        self.id = id
        self.paneID = paneID
        self.sessionID = sessionID
        self.order = order
        self.title = title
        self.status = status
    }

    /// Compares node content while preserving exact optional session bytes.
    public static func == (lhs: NestedAgentNode, rhs: NestedAgentNode) -> Bool {
        lhs.id == rhs.id
            && lhs.paneID == rhs.paneID
            && lhs.sessionID.map(ExactUTF8String.init)
                == rhs.sessionID.map(ExactUTF8String.init)
            && lhs.order == rhs.order
            && lhs.title == rhs.title
            && lhs.status == rhs.status
    }

    /// Decodes an agent while preserving opaque session bytes.
    ///
    /// - Parameter decoder: Decoder containing the provider-owned agent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(NestedNodeID.self, forKey: .id)
        paneID = try container.decode(NestedNodeID.self, forKey: .paneID)
        sessionID = try container.decodeIfPresent(
            ExactUTF8String.self,
            forKey: .sessionID
        )?.value
        order = try container.decode(Int.self, forKey: .order)
        title = try container.decodeIfPresent(NestedNodeTitle.self, forKey: .title)
        status = try container.decode(NestedAgentStatus.self, forKey: .status)
    }

    /// Encodes an agent with a byte-exact optional session value.
    ///
    /// - Parameter encoder: Encoder receiving the provider-owned agent.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(paneID, forKey: .paneID)
        try container.encodeIfPresent(
            sessionID.map(ExactUTF8String.init),
            forKey: .sessionID
        )
        try container.encode(order, forKey: .order)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(status, forKey: .status)
    }

    func mergingUpdate(_ candidate: NestedAgentNode) -> NestedAgentNode {
        NestedAgentNode(
            id: id,
            paneID: candidate.paneID,
            sessionID: candidate.sessionID,
            order: candidate.order,
            title: title?.replacingFromProvider(with: candidate.title) ?? candidate.title,
            status: candidate.status
        )
    }

    func replacingTitle(with title: NestedNodeTitle) -> NestedAgentNode {
        NestedAgentNode(
            id: id,
            paneID: paneID,
            sessionID: sessionID,
            order: order,
            title: self.title?.replacing(withLocalLock: title) ?? title,
            status: status
        )
    }

    func precedes(_ candidate: NestedAgentNode) -> Bool {
        let parent = ExactUTF8String(paneID.rawID)
        let candidateParent = ExactUTF8String(candidate.paneID.rawID)
        if parent != candidateParent {
            return parent < candidateParent
        }
        return order == candidate.order
            ? ExactUTF8String(id.rawID) < ExactUTF8String(candidate.id.rawID)
            : order < candidate.order
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case paneID
        case sessionID
        case order
        case title
        case status
    }
}

extension NestedAgentNode: NestedTopologyTitledNode {}
