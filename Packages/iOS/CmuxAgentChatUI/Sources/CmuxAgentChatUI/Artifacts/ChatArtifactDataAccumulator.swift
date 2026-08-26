import Foundation

/// Accumulates non-text artifact chunks away from the main actor.
actor ChatArtifactDataAccumulator {
    private var data = Data()

    func append(_ chunk: Data, totalSize: Int64) {
        if data.isEmpty, totalSize > 0, totalSize <= Int64(Int.max) {
            data.reserveCapacity(Int(totalSize))
        }
        data.append(chunk)
    }

    func value() -> Data {
        data
    }
}
