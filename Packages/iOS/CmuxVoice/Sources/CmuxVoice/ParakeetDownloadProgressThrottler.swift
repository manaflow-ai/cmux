import Foundation

struct ParakeetDownloadProgressThrottler: Sendable {
    private let totalBytes: Int64
    private let minimumByteDelta: Int64
    private let minimumFractionDelta: Double
    private var lastEmittedBytes: Int64

    init(
        totalBytes: Int64,
        minimumByteDelta: Int64 = 256 * 1024,
        minimumFractionDelta: Double = 0.005
    ) {
        self.totalBytes = max(totalBytes, 0)
        self.minimumByteDelta = max(minimumByteDelta, 1)
        self.minimumFractionDelta = max(minimumFractionDelta, 0)
        self.lastEmittedBytes = 0
    }

    mutating func progressIfNeeded(downloadedBytes: Int64) -> ParakeetDownloadProgress? {
        let clampedBytes = min(max(downloadedBytes, 0), totalBytes)
        guard totalBytes > 0 else { return nil }
        guard clampedBytes > lastEmittedBytes else { return nil }

        let byteDelta = clampedBytes - lastEmittedBytes
        let fractionDelta = Double(byteDelta) / Double(totalBytes)
        guard
            clampedBytes == totalBytes
                || byteDelta >= minimumByteDelta
                || fractionDelta >= minimumFractionDelta
        else {
            return nil
        }

        lastEmittedBytes = clampedBytes
        return ParakeetDownloadProgress(
            fractionCompleted: Double(clampedBytes) / Double(totalBytes),
            phaseDescription: "downloading"
        )
    }
}
