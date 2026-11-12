import Foundation

/// Errors surfaced by ``SFTPClient``.
public enum SFTPError: Error, Equatable, Sendable {
    /// The path does not exist (`SSH_FX_NO_SUCH_FILE`).
    case noSuchFile
    /// The server refused access (`SSH_FX_PERMISSION_DENIED`).
    case permissionDenied
    /// Any other server-reported failure, with the server's message.
    case failure(String)
    /// The channel closed or a write to it failed. No further requests succeed.
    case connectionLost
    /// The server sent a packet the protocol does not allow here.
    case unexpectedPacket(String)
}

/// File attributes (SFTP v3 `ATTRS`). Fields the server omitted are `nil`.
public struct SFTPAttributes: Sendable, Equatable {
    public var size: UInt64?
    public var uid: UInt32?
    public var gid: UInt32?
    /// POSIX mode bits including the file type (`S_IFMT`).
    public var permissions: UInt32?
    public var accessTime: Date?
    public var modificationTime: Date?

    public init(
        size: UInt64? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        permissions: UInt32? = nil,
        accessTime: Date? = nil,
        modificationTime: Date? = nil
    ) {
        self.size = size
        self.uid = uid
        self.gid = gid
        self.permissions = permissions
        self.accessTime = accessTime
        self.modificationTime = modificationTime
    }

    private var fileType: UInt32? { permissions.map { $0 & 0o170000 } }
    public var isDirectory: Bool { fileType == 0o040000 }
    public var isSymlink: Bool { fileType == 0o120000 }
    public var isRegularFile: Bool { fileType == 0o100000 }
}

/// One directory entry from `READDIR`.
public struct SFTPEntry: Sendable, Equatable {
    /// File name within the listed directory.
    public var name: String
    /// The server's `ls -l` style line. Informational only.
    public var longname: String
    public var attributes: SFTPAttributes

    public var isDirectory: Bool { attributes.isDirectory }
    public var isSymlink: Bool { attributes.isSymlink }
}

/// Transfer progress reported after each completed chunk.
public struct SFTPTransferProgress: Sendable, Equatable {
    public var bytesTransferred: UInt64
    /// Expected total, when known up front.
    public var totalBytes: UInt64?
}
