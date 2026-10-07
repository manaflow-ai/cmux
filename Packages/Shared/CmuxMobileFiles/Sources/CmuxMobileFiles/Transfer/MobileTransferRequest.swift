import CmuxMobileWire
import Foundation

/// What to transfer. Upload: `localURL` is the staged file, `dest` where it
/// lands. Download: `remotePath` on the Mac into `localURL`.
public struct MobileTransferRequest: Hashable, Sendable {
    public var id: String
    public var hostID: String
    public var direction: TransferDirection
    public var localURL: URL
    public var remotePath: String
    public var name: String
    public var mime: String
    public var dest: FilesUploadDestination?

    public init(id: String = UUID().uuidString.lowercased(), hostID: String, direction: TransferDirection, localURL: URL,
                remotePath: String = "", name: String, mime: String = "application/octet-stream",
                dest: FilesUploadDestination? = nil) {
        self.id = id
        self.hostID = hostID
        self.direction = direction
        self.localURL = localURL
        self.remotePath = remotePath
        self.name = name
        self.mime = mime
        self.dest = dest
    }
}
