/// Resource bounds for ``NestedTopologyAttachmentCoordinator``.
public struct NestedAttachmentLimits: Hashable, Codable, Sendable {
    /// Maximum simultaneously retained attachments (any non-removed state).
    public var maxConcurrentAttachments: Int
    /// Maximum UTF-8 bytes accepted for a host workspace ID string.
    public var maxHostWorkspaceIDUTF8ByteCount: Int
    /// Maximum UTF-8 bytes accepted for control-socket authorization request IDs.
    public var maxAuthorizationRequestIDUTF8ByteCount: Int

    /// Default production limits.
    public static let `default` = NestedAttachmentLimits(
        maxConcurrentAttachments: 32,
        maxHostWorkspaceIDUTF8ByteCount: 256,
        maxAuthorizationRequestIDUTF8ByteCount: 128
    )

    /// Creates attachment limits.
    public init(
        maxConcurrentAttachments: Int,
        maxHostWorkspaceIDUTF8ByteCount: Int,
        maxAuthorizationRequestIDUTF8ByteCount: Int
    ) {
        self.maxConcurrentAttachments = maxConcurrentAttachments
        self.maxHostWorkspaceIDUTF8ByteCount = maxHostWorkspaceIDUTF8ByteCount
        self.maxAuthorizationRequestIDUTF8ByteCount = maxAuthorizationRequestIDUTF8ByteCount
    }
}
