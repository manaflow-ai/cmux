import Darwin
public import Foundation

/// The outcome of draining a pipe to end-of-file: every byte read before the
/// stream ended, plus the read error that interrupted the drain, if any.
public struct ProcessPipeEndRead: Equatable, Sendable {
    // Darwin's FIONREAD macro is not imported into Swift because it expands
    // through `_IOR`. This is `_IOR('f', 127, Int32)` from sys/filio.h.
    private static let bytesAvailableIOControlRequest =
        UInt(0x4000_0000)
        | (UInt(MemoryLayout<Int32>.size) << 16)
        | UInt(0x66_7f)

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
            var bytesRemainingAtStop: Int?
            if isStopping {
                var availableBytes: Int32 = 0
                guard Darwin.ioctl(
                    fileDescriptor,
                    Self.bytesAvailableIOControlRequest,
                    &availableBytes
                ) == 0 else {
                    return ProcessPipeEndRead(
                        data: data,
                        readError: ProcessPipeReadError(
                            operation: "readDataToEndOfFile.ioctl",
                            errnoCode: errno
                        )
                    )
                }
                bytesRemainingAtStop = Int(availableBytes)
                if availableBytes == 0 {
                    return ProcessPipeEndRead(data: data, readError: nil)
                }
            }

            repeat {
                let maximumReadLength = bytesRemainingAtStop.map {
                    min(chunkSize, $0)
                } ?? chunkSize
                switch ProcessPipeAvailableRead.readOnceIfReady(
                    fileDescriptor: fileDescriptor,
                    maxLength: maximumReadLength,
                    operation: "readDataToEndOfFile"
                ) {
                case .success(.data(let chunk)):
                    data.append(chunk)
                    if let remaining = bytesRemainingAtStop.map({ $0 - chunk.count }) {
                        if remaining <= 0 {
                            return ProcessPipeEndRead(data: data, readError: nil)
                        }
                        bytesRemainingAtStop = remaining
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
            } while isStopping

            if isStopping {
                return ProcessPipeEndRead(data: data, readError: nil)
            }
        }
    }
}
