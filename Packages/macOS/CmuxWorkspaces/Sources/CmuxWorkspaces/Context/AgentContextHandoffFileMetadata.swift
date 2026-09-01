import Foundation

/// Typed metadata the handoff verifier needs from its filesystem boundary.
nonisolated struct AgentContextHandoffFileMetadata: Equatable, Sendable {
    /// Creates metadata captured from one open file descriptor.
    init(
        isRegularFile: Bool,
        modificationDate: Date?,
        size: Int,
        deviceID: UInt64? = nil,
        fileID: UInt64? = nil
    ) {
        self.isRegularFile = isRegularFile
        self.modificationDate = modificationDate
        self.size = size
        self.deviceID = deviceID
        self.fileID = fileID
    }

    /// Whether the path currently identifies a regular file.
    let isRegularFile: Bool
    /// The file's modification date, when the filesystem provided one.
    let modificationDate: Date?
    /// The byte size reported by the filesystem.
    let size: Int
    /// The device identity reported by the filesystem, when available.
    let deviceID: UInt64?
    /// The inode/file identity reported by the filesystem, when available.
    let fileID: UInt64?
}
