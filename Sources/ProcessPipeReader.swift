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

enum ProcessPipeReader {
    static let defaultChunkSize = 64 * 1024

    static func readAvailableData(
        from fileHandle: FileHandle,
        maxLength: Int = defaultChunkSize
    ) -> Result<Data, ProcessPipeReadError> {
        readOnceNonBlocking(
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

    static func readAvailableDataOrEmpty(from fileHandle: FileHandle) -> Data {
        switch readAvailableData(from: fileHandle) {
        case .success(let data):
            return data
        case .failure(let error):
            logReadFailure(
                error,
                fileDescriptor: fileHandle.fileDescriptor,
                partialByteCount: 0
            )
            fileHandle.readabilityHandler = nil
            return Data()
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
        operation: String,
        treatWouldBlockAsEmpty: Bool = false
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
            if treatWouldBlockAsEmpty && (code == EAGAIN || code == EWOULDBLOCK) {
                return .success(Data())
            }
            return .failure(ProcessPipeReadError(operation: operation, errnoCode: code))
        }
    }

    private static func readOnceNonBlocking(
        fileDescriptor: Int32,
        maxLength: Int,
        operation: String
    ) -> Result<Data, ProcessPipeReadError> {
        guard maxLength > 0 else { return .success(Data()) }

        let originalFlags = Darwin.fcntl(fileDescriptor, F_GETFL)
        guard originalFlags != -1 else {
            return .failure(ProcessPipeReadError(
                operation: "\(operation).fcntlGetFlags",
                errnoCode: errno
            ))
        }

        let shouldRestoreFlags = (originalFlags & O_NONBLOCK) == 0
        if shouldRestoreFlags {
            guard Darwin.fcntl(fileDescriptor, F_SETFL, originalFlags | O_NONBLOCK) != -1 else {
                return .failure(ProcessPipeReadError(
                    operation: "\(operation).fcntlSetNonBlocking",
                    errnoCode: errno
                ))
            }
        }

        let result = readOnce(
            fileDescriptor: fileDescriptor,
            maxLength: maxLength,
            operation: operation,
            treatWouldBlockAsEmpty: true
        )

        if shouldRestoreFlags,
           Darwin.fcntl(fileDescriptor, F_SETFL, originalFlags) == -1 {
            let restoreError = ProcessPipeReadError(
                operation: "\(operation).fcntlRestoreFlags",
                errnoCode: errno
            )
            let partialByteCount: Int
            switch result {
            case .success(let data):
                partialByteCount = data.count
            case .failure:
                partialByteCount = 0
            }
            logReadFailure(
                restoreError,
                fileDescriptor: fileDescriptor,
                partialByteCount: partialByteCount
            )
        }

        return result
    }
}
