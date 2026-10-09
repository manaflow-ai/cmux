import CmuxMobileWire
import Foundation

/// One transfer as the phone's journal keeps it, so it can resume after the
/// session or the app went away (c4-files.md section 4).
public struct TransferRecord: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var hostID: String
    public var direction: TransferDirection
    /// Upload: the staged source. Download: the final local file.
    public var localPath: String
    /// Upload: the requested destination (`dest.path`, or empty). Download: the Mac path.
    public var remotePath: String
    public var name: String
    public var mime: String
    public var dest: FilesUploadDestination?
    public var size: UInt64?
    /// Upload: of the source. Download: the Mac's digest at the first open.
    public var sha256: String?
    public var completedBytes: UInt64
    public var status: TransferStatus
    /// Upload: the Mac path from `files.upload.done`.
    public var resultPath: String?
    /// The Mac-issued upload reference; older journal entries decode as nil.
    public var uploadID: String?
    public var createdAt: Date

    public init(id: String, hostID: String, direction: TransferDirection, localPath: String, remotePath: String,
                name: String, mime: String, dest: FilesUploadDestination? = nil, size: UInt64? = nil,
                sha256: String? = nil, completedBytes: UInt64 = 0, status: TransferStatus = .running,
                resultPath: String? = nil, uploadID: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.hostID = hostID
        self.direction = direction
        self.localPath = localPath
        self.remotePath = remotePath
        self.name = name
        self.mime = mime
        self.dest = dest
        self.size = size
        self.sha256 = sha256
        self.completedBytes = completedBytes
        self.status = status
        self.resultPath = resultPath
        self.uploadID = uploadID
        self.createdAt = createdAt
    }

    /// Where a download's bytes go until verified.
    public var partPath: String { localPath + ".cmuxpart" }
}
