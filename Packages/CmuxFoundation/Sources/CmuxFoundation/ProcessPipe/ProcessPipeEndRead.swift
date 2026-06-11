public import Foundation

/// The outcome of draining a pipe to end-of-file: every byte read before the
/// stream ended, plus the read error that interrupted the drain, if any.
public struct ProcessPipeEndRead: Equatable, Sendable {
    /// The bytes successfully read before EOF or the failure.
    public let data: Data
    /// The error that ended the drain early, or `nil` on a clean EOF.
    public let readError: ProcessPipeReadError?

    /// Creates an end-read value; mirrors the original memberwise initializer.
    public init(data: Data, readError: ProcessPipeReadError?) {
        self.data = data
        self.readError = readError
    }

    /// Drains `fileDescriptor` to end-of-file through `readChunk`, preserving
    /// partial data when a later read fails.
    ///
    /// `readChunk` receives `(fileDescriptor, maxLength, operation)` and
    /// returns one chunk; an empty chunk means EOF. This is the injectable
    /// core behind ``Foundation/FileHandle/readToEndOfFileCapturingError(chunkSize:)``
    /// and is public so tests can pin the partial-data-on-failure contract
    /// without a real descriptor.
    public static func reading(
        fileDescriptor: Int32,
        chunkSize: Int = FileHandle.processPipeReadChunkSize,
        readChunk: (Int32, Int, String) -> Result<Data, ProcessPipeReadError>
    ) -> ProcessPipeEndRead {
        var data = Data()
        while true {
            switch readChunk(fileDescriptor, chunkSize, "readDataToEndOfFile") {
            case .success(let chunk):
                guard !chunk.isEmpty else {
                    return ProcessPipeEndRead(data: data, readError: nil)
                }
                data.append(chunk)
            case .failure(let error):
                return ProcessPipeEndRead(data: data, readError: error)
            }
        }
    }
}
