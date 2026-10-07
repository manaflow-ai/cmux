/// One progress report. The stream ends after a terminal status, `paused`,
/// or a retryable failure.
public struct MobileTransferUpdate: Hashable, Sendable {
    public var id: String
    public var completedBytes: UInt64
    public var totalBytes: UInt64?
    public var status: TransferStatus
    /// Upload: the Mac path once finished.
    public var resultPath: String?
    /// The Mac-issued upload reference, present only after a verified upload.
    public var uploadID: String?

    public init(id: String, completedBytes: UInt64, totalBytes: UInt64?, status: TransferStatus, resultPath: String? = nil,
                uploadID: String? = nil) {
        self.id = id
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.status = status
        self.resultPath = resultPath
        self.uploadID = uploadID
    }
}
