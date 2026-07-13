import Darwin
public import Foundation
import OSLog

// Same subsystem/category as the original app-target ProcessPipeReader so
// existing log queries keep working after the move into CmuxFoundation.
nonisolated private let processPipeReaderLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "ProcessPipeReader"
)

extension FileHandle {
    /// Default read chunk size for the process-pipe reading helpers (64 KiB).
    public static let processPipeReadChunkSize = 64 * 1024

    /// One non-blocking read attempt: polls for readability, then reads up to
    /// `maxLength` bytes, distinguishing buffered data, would-block, and EOF.
    public func readAvailableData(
        maxLength: Int = FileHandle.processPipeReadChunkSize
    ) -> Result<ProcessPipeAvailableRead, ProcessPipeReadError> {
        ProcessPipeAvailableRead.readOnceIfReady(
            fileDescriptor: fileDescriptor,
            maxLength: maxLength,
            operation: "readAvailableData"
        )
    }

    /// ``readAvailableData(maxLength:)`` with read failures logged, the
    /// readability handler detached, and the failure mapped to `.endOfFile`,
    /// matching how readability-handler callers treat a broken descriptor as
    /// a closed pipe.
    public func readAvailableDataOrEndOfFile() -> ProcessPipeAvailableRead {
        switch readAvailableData() {
        case .success(let result):
            return result
        case .failure(let error):
            error.logReadFailure(
                fileDescriptor: fileDescriptor,
                partialByteCount: 0
            )
            readabilityHandler = nil
            return .endOfFile
        }
    }

    /// Drains the handle to end-of-file, returning partial data plus the
    /// error when a read fails mid-drain (unlike Foundation's
    /// `readDataToEndOfFile`, which traps).
    public func readToEndOfFileCapturingError(
        chunkSize: Int = FileHandle.processPipeReadChunkSize
    ) -> ProcessPipeEndRead {
        ProcessPipeEndRead.reading(
            fileDescriptor: fileDescriptor,
            chunkSize: chunkSize
        )
    }

    /// ``readToEndOfFileCapturingError(chunkSize:)`` with failures logged and
    /// the partial data returned, for callers that treat a broken pipe as
    /// best-effort output capture.
    public func readDataToEndOfFileOrEmpty() -> Data {
        let result = readToEndOfFileCapturingError()
        if let error = result.readError {
            error.logReadFailure(
                fileDescriptor: fileDescriptor,
                partialByteCount: result.data.count
            )
        }
        return result.data
    }

    /// Streams this handle's bytes into `output` until EOF, throwing on the
    /// first read or write failure (after logging it).
    public func copyDataToEndOfFile(to output: FileHandle) throws {
        var copiedBytes = 0
        while true {
            switch ProcessPipeAvailableRead.readOnce(
                fileDescriptor: fileDescriptor,
                maxLength: FileHandle.processPipeReadChunkSize,
                operation: "copyDataToEndOfFile"
            ) {
            case .success(let data):
                guard !data.isEmpty else { return }
                do {
                    try output.write(contentsOf: data)
                    copiedBytes += data.count
                } catch {
                    ProcessPipeReadError(operation: "copyDataToEndOfFile.write", errnoCode: EIO)
                        .logReadFailure(
                            fileDescriptor: fileDescriptor,
                            partialByteCount: copiedBytes
                        )
                    throw error
                }
            case .failure(let error):
                error.logReadFailure(
                    fileDescriptor: fileDescriptor,
                    partialByteCount: copiedBytes
                )
                throw error
            }
        }
    }
}

extension ProcessPipeReadError {
    fileprivate func logReadFailure(fileDescriptor: Int32, partialByteCount: Int) {
        processPipeReaderLogger.warning(
            "processPipeReader.readFailed operation=\(operation, privacy: .public) errno=\(Int(errnoCode), privacy: .public) message=\(message, privacy: .public) fd=\(fileDescriptor, privacy: .public) partialBytes=\(partialByteCount, privacy: .public)"
        )
    }
}
