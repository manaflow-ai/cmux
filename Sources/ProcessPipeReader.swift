import Darwin
import Foundation
import OSLog

nonisolated private let processPipeReaderLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "ProcessPipeReader"
)

struct ProcessPipeReadError: Error, Equatable, Sendable {
    let operation: String
    let errnoCode: Int32

    var message: String {
        String(cString: strerror(errnoCode))
    }
}

extension ProcessPipeReadError: LocalizedError {
    var errorDescription: String? {
        "\(operation) failed: \(message)"
    }
}

struct ProcessPipeEndRead: Equatable, Sendable {
    let data: Data
    let readError: ProcessPipeReadError?
}

enum ProcessPipeAvailableRead: Equatable, Sendable {
    case data(Data)
    case wouldBlock
    case endOfFile
}

enum ProcessPipeReader {
    static let defaultChunkSize = 64 * 1024

    static func readAvailableData(
        from fileHandle: FileHandle,
        maxLength: Int = defaultChunkSize
    ) -> Result<ProcessPipeAvailableRead, ProcessPipeReadError> {
        readOnceIfReady(
            fileDescriptor: fileHandle.fileDescriptor,
            maxLength: maxLength,
            operation: "readAvailableData"
        )
    }

    static func readDataToEndOfFile(
        from fileHandle: FileHandle,
        chunkSize: Int = defaultChunkSize
    ) -> ProcessPipeEndRead {
        readDataToEndOfFile(
            fileDescriptor: fileHandle.fileDescriptor,
            chunkSize: chunkSize
        ) { fileDescriptor, maxLength, operation in
            readOnce(
                fileDescriptor: fileDescriptor,
                maxLength: maxLength,
                operation: operation
            )
        }
    }

    static func readDataToEndOfFile(
        fileDescriptor: Int32,
        chunkSize: Int = defaultChunkSize,
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

    static func readDataToEndOfFileOrEmpty(from fileHandle: FileHandle) -> Data {
        let result = readDataToEndOfFile(from: fileHandle)
        if let error = result.readError {
            logReadFailure(
                error,
                fileDescriptor: fileHandle.fileDescriptor,
                partialByteCount: result.data.count
            )
        }
        return result.data
    }

    static func copyDataToEndOfFile(from input: FileHandle, to output: FileHandle) throws {
        var copiedBytes = 0
        while true {
            switch readOnce(
                fileDescriptor: input.fileDescriptor,
                maxLength: defaultChunkSize,
                operation: "copyDataToEndOfFile"
            ) {
            case .success(let data):
                guard !data.isEmpty else { return }
                do {
                    try output.write(contentsOf: data)
                    copiedBytes += data.count
                } catch {
                    logReadFailure(
                        ProcessPipeReadError(operation: "copyDataToEndOfFile.write", errnoCode: EIO),
                        fileDescriptor: input.fileDescriptor,
                        partialByteCount: copiedBytes
                    )
                    throw error
                }
            case .failure(let error):
                logReadFailure(
                    error,
                    fileDescriptor: input.fileDescriptor,
                    partialByteCount: copiedBytes
                )
                throw error
            }
        }
    }

    static func readAvailableDataOrEndOfFile(from fileHandle: FileHandle) -> ProcessPipeAvailableRead {
        switch readAvailableData(from: fileHandle) {
        case .success(let result):
            return result
        case .failure(let error):
            logReadFailure(
                error,
                fileDescriptor: fileHandle.fileDescriptor,
                partialByteCount: 0
            )
            fileHandle.readabilityHandler = nil
            return .endOfFile
        }
    }

    private static func logReadFailure(
        _ error: ProcessPipeReadError,
        fileDescriptor: Int32,
        partialByteCount: Int
    ) {
        processPipeReaderLogger.warning(
            "processPipeReader.readFailed operation=\(error.operation, privacy: .public) errno=\(Int(error.errnoCode), privacy: .public) message=\(error.message, privacy: .public) fd=\(fileDescriptor, privacy: .public) partialBytes=\(partialByteCount, privacy: .public)"
        )
    }

    private static func readOnce(
        fileDescriptor: Int32,
        maxLength: Int,
        operation: String
    ) -> Result<Data, ProcessPipeReadError> {
        guard maxLength > 0 else { return .success(Data()) }

        var buffer = [UInt8](repeating: 0, count: maxLength)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let baseAddress = pointer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, baseAddress, maxLength)
            }

            if bytesRead > 0 {
                return .success(Data(buffer.prefix(bytesRead)))
            }
            if bytesRead == 0 {
                return .success(Data())
            }

            let code = errno
            if code == EINTR {
                continue
            }
            return .failure(ProcessPipeReadError(operation: operation, errnoCode: code))
        }
    }

    private static func readAvailableOnce(
        fileDescriptor: Int32,
        maxLength: Int,
        operation: String
    ) -> Result<ProcessPipeAvailableRead, ProcessPipeReadError> {
        guard maxLength > 0 else { return .success(.wouldBlock) }

        var buffer = [UInt8](repeating: 0, count: maxLength)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let baseAddress = pointer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, baseAddress, maxLength)
            }

            if bytesRead > 0 {
                return .success(.data(Data(buffer.prefix(bytesRead))))
            }
            if bytesRead == 0 {
                return .success(.endOfFile)
            }

            let code = errno
            if code == EINTR {
                continue
            }
            if code == EAGAIN || code == EWOULDBLOCK {
                return .success(.wouldBlock)
            }
            return .failure(ProcessPipeReadError(operation: operation, errnoCode: code))
        }
    }

    private static func readOnceIfReady(
        fileDescriptor: Int32,
        maxLength: Int,
        operation: String
    ) -> Result<ProcessPipeAvailableRead, ProcessPipeReadError> {
        guard maxLength > 0 else { return .success(.wouldBlock) }

        // Do not toggle O_NONBLOCK here. The flag lives on the open file description,
        // so changing it can affect concurrent writers that share a socket fd.
        var descriptor = pollfd(
            fd: fileDescriptor,
            events: Int16(POLLIN | POLLERR | POLLHUP),
            revents: 0
        )
        while true {
            let pollResult = Darwin.poll(&descriptor, 1, 0)
            if pollResult > 0 {
                break
            }
            if pollResult == 0 {
                return .success(.wouldBlock)
            }

            let code = errno
            if code == EINTR {
                continue
            }
            return .failure(ProcessPipeReadError(
                operation: "\(operation).poll",
                errnoCode: code
            ))
        }

        if (descriptor.revents & Int16(POLLNVAL)) != 0 {
            return .failure(ProcessPipeReadError(
                operation: "\(operation).poll",
                errnoCode: EBADF
            ))
        }

        guard (descriptor.revents & Int16(POLLIN | POLLERR | POLLHUP)) != 0 else {
            return .success(.wouldBlock)
        }

        return readAvailableOnce(
            fileDescriptor: fileDescriptor,
            maxLength: maxLength,
            operation: operation
        )
    }
}
