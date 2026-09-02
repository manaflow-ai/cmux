/// Security-validated local Unix socket endpoint for one nested-provider attachment.
public struct NestedAttachmentEndpoint: Hashable, Codable, Sendable {
    /// Canonical absolute path (parent symlinks resolved; final component not followed).
    public let canonicalPath: String
    /// Pre-connect `lstat` identity pinned for this connection attempt.
    public let fileIdentity: NestedUnixSocketFileIdentity
    /// Owner UID observed during validation.
    public let ownerUID: UInt32
    /// Permission bits (`st_mode & 0o777`) observed during validation.
    public let permissionBits: UInt32

    enum CodingKeys: String, CodingKey {
        case canonicalPath = "canonical_path"
        case fileIdentity = "file_identity"
        case ownerUID = "owner_uid"
        case permissionBits = "permission_bits"
    }

    /// Creates a validated endpoint descriptor.
    public init(
        canonicalPath: String,
        fileIdentity: NestedUnixSocketFileIdentity,
        ownerUID: UInt32,
        permissionBits: UInt32
    ) {
        self.canonicalPath = canonicalPath
        self.fileIdentity = fileIdentity
        self.ownerUID = ownerUID
        self.permissionBits = permissionBits
    }
}
