import Foundation

/// Locations and caps of the files service (c4-files.md section 3).
public struct MobileFilesConfiguration: Sendable {
    /// The Mac user's home; roots must be strictly inside it.
    public var homeDirectory: URL
    /// Where `terminal` and `composer` uploads land (created 0700).
    public var inbox: URL
    /// Upload partials, outside TCC-protected folders until the final move.
    public var stagingDirectory: URL
    public var maxUploadBytes: UInt64
    public var maxDownloadBytes: UInt64
    /// Payload bytes per download chunk (below `hello.ok.max_frame`).
    public var chunkBytes: Int
    /// Staged partial bytes per device.
    public var stagingQuotaBytes: UInt64
    /// A partial expires this long after its last write.
    public var partialLifetime: TimeInterval
    /// Free disk that must remain after an upload.
    public var freeSpaceMarginBytes: UInt64
    public var listDefaultLimit: Int
    public var listMaxLimit: Int

    public init(homeDirectory: URL, inbox: URL? = nil, stagingDirectory: URL? = nil,
                maxUploadBytes: UInt64 = 1 << 30, maxDownloadBytes: UInt64 = 1 << 30, chunkBytes: Int = 128 * 1024,
                stagingQuotaBytes: UInt64 = 2 << 30, partialLifetime: TimeInterval = 24 * 60 * 60,
                freeSpaceMarginBytes: UInt64 = 1 << 30, listDefaultLimit: Int = 200, listMaxLimit: Int = 1000) {
        self.homeDirectory = homeDirectory
        self.inbox = inbox ?? homeDirectory.appendingPathComponent("Downloads/cmux-phone", isDirectory: true)
        self.stagingDirectory = stagingDirectory
            ?? homeDirectory.appendingPathComponent("Library/Caches/cmux/phone-uploads", isDirectory: true)
        self.maxUploadBytes = maxUploadBytes
        self.maxDownloadBytes = maxDownloadBytes
        self.chunkBytes = max(1024, chunkBytes)
        self.stagingQuotaBytes = stagingQuotaBytes
        self.partialLifetime = partialLifetime
        self.freeSpaceMarginBytes = freeSpaceMarginBytes
        self.listDefaultLimit = listDefaultLimit
        self.listMaxLimit = listMaxLimit
    }

    /// The signed-in Mac user's locations.
    public static var standard: MobileFilesConfiguration {
        MobileFilesConfiguration(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }
}
