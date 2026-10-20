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
    /// Drains `fileDescriptor` to end-of-file with blocking `read(2)` chunks,
    /// preserving partial data when a later read fails.
    ///
    /// Raw-descriptor variant of
    /// ``Foundation/FileHandle/readToEndOfFileCapturingError(chunkSize:)`` for
    /// callers that must snapshot the descriptor up front because the owning
    /// `FileHandle` may be closed concurrently mid-drain (a closed handle's
    /// `fileDescriptor` accessor raises an uncatchable ObjC exception, whereas
    /// `read(2)` on a closed descriptor fails cleanly with `EBADF`).
    public static func reading(
        fileDescriptor: Int32,
        chunkSize: Int = FileHandle.processPipeReadChunkSize
    ) -> ProcessPipeEndRead {
        reading(fileDescriptor: fileDescriptor, chunkSize: chunkSize) { fileDescriptor, maxLength, operation in
            ProcessPipeAvailableRead.readOnce(
                fileDescriptor: fileDescriptor,
                maxLength: maxLength,
                operation: operation
            )
        }
    }

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
