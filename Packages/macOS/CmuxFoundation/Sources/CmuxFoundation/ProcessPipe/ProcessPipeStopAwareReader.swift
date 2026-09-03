import Darwin
public import Foundation

/// Drains a process pipe until EOF or a separate stop descriptor fires.
public struct ProcessPipeStopAwareReader: Sendable {
    // Darwin's FIONREAD macro is not imported into Swift because it expands
    // through `_IOR`. This is `_IOR('f', 127, Int32)` from sys/filio.h.
    private static let bytesAvailableIOControlRequest =
        UInt(0x4000_0000)
        | (UInt(MemoryLayout<Int32>.size) << 16)
        | UInt(0x66_7f)

    private let fileDescriptor: Int32
    private let chunkSize: Int
    private let stopFileDescriptor: Int32

    /// Creates a stop-aware pipe reader.
    ///
    /// - Parameters:
    ///   - fileDescriptor: The process-pipe descriptor to drain.
    ///   - chunkSize: The requested maximum bytes read per operation.
    ///     Non-positive values are normalized to one byte.
    ///   - stopFileDescriptor: A descriptor whose readiness ends the drain
    ///     after bytes already buffered in `fileDescriptor` are preserved.
    public init(
        fileDescriptor: Int32,
        chunkSize: Int = FileHandle.processPipeReadChunkSize,
        stopFileDescriptor: Int32
    ) {
        self.fileDescriptor = fileDescriptor
        self.chunkSize = max(1, chunkSize)
        self.stopFileDescriptor = stopFileDescriptor
    }

    /// Drains the pipe, preserving bytes buffered when the stop signal fires.
    ///
    /// - Returns: The captured bytes and any read failure.
    public func readToEnd() -> ProcessPipeEndRead {
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
            let pollResult = Darwin.poll(
                &descriptors,
                nfds_t(descriptors.count),
                -1
            )
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
                    if let remaining = bytesRemainingAtStop.map({
                        $0 - chunk.count
                    }) {
                        if remaining <= 0 {
                            return ProcessPipeEndRead(
                                data: data,
                                readError: nil
                            )
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
