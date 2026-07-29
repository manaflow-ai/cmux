import Darwin
public import Foundation

/// A one-shot signal that wakes process-pipe readers without periodic polling.
///
/// Closing the pipe's write end leaves the read end permanently hung up, so
/// every reader polling the same signal wakes even when another reader returns
/// first. The owner must retain the signal until all readers have stopped.
public final class ProcessPipeStopSignal: @unchecked Sendable {
    public let readFileDescriptor: Int32

    private let lock = NSLock()
    private var writeFileDescriptor: Int32

    public init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        readFileDescriptor = descriptors[0]
        writeFileDescriptor = descriptors[1]
        guard fcntl(readFileDescriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(writeFileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            Darwin.close(readFileDescriptor)
            Darwin.close(writeFileDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    public func signal() {
        let descriptor = lock.withLock {
            let descriptor = writeFileDescriptor
            writeFileDescriptor = -1
            return descriptor
        }
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    deinit {
        signal()
        Darwin.close(readFileDescriptor)
    }
}

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

    /// Drains a process pipe until EOF or until `stopFileDescriptor` becomes
    /// readable or hung up. On stop it preserves bytes already buffered in the
    /// pipe, then returns without waiting for a future writer or an inherited
    /// descriptor to close.
    public static func reading(
        fileDescriptor: Int32,
        chunkSize: Int = FileHandle.processPipeReadChunkSize,
        stopFileDescriptor: Int32
    ) -> ProcessPipeEndRead {
        var data = Data()
        let maximumStopDrainCount = 16

        while true {
            var descriptors = [
                pollfd(
                    fd: fileDescriptor,
                    events: Int16(POLLIN | POLLERR | POLLHUP),
                    revents: 0
                ),
                pollfd(
                    fd: stopFileDescriptor,
                    events: Int16(POLLIN | POLLERR | POLLHUP),
                    revents: 0
                ),
            ]
            let pollResult = Darwin.poll(&descriptors, nfds_t(descriptors.count), -1)
            if pollResult < 0 {
                let code = errno
                if code == EINTR {
                    continue
                }
                return ProcessPipeEndRead(
                    data: data,
                    readError: ProcessPipeReadError(
                        operation: "readDataToEndOfFile.poll",
                        errnoCode: code
                    )
                )
            }
            if (descriptors[0].revents & Int16(POLLNVAL)) != 0 {
                return ProcessPipeEndRead(
                    data: data,
                    readError: ProcessPipeReadError(
                        operation: "readDataToEndOfFile.poll",
                        errnoCode: EBADF
                    )
                )
            }

            let isStopping = descriptors[1].revents != 0
            var stopDrainCount = 0
            repeat {
                switch ProcessPipeAvailableRead.readOnceIfReady(
                    fileDescriptor: fileDescriptor,
                    maxLength: chunkSize,
                    operation: "readDataToEndOfFile"
                ) {
                case .success(.data(let chunk)):
                    data.append(chunk)
                    if isStopping {
                        stopDrainCount += 1
                    }
                case .success(.wouldBlock):
                    if isStopping {
                        return ProcessPipeEndRead(data: data, readError: nil)
                    }
                    break
                case .success(.endOfFile):
                    return ProcessPipeEndRead(data: data, readError: nil)
                case .failure(let error):
                    return ProcessPipeEndRead(data: data, readError: error)
                }
            } while isStopping && stopDrainCount < maximumStopDrainCount

            if isStopping {
                return ProcessPipeEndRead(data: data, readError: nil)
            }
        }
    }
}
