import Darwin
import Foundation

struct ProcessPipeReadError: Error, Equatable, Sendable {
    let operation: String
    let errnoCode: Int32

    var message: String {
        String(cString: strerror(errnoCode))
    }
}

enum ProcessPipeReader {
    static let defaultChunkSize = 64 * 1024

    static func readAvailableData(
        from fileHandle: FileHandle,
        maxLength: Int = defaultChunkSize
    ) -> Result<Data, ProcessPipeReadError> {
        readOnce(
            fileDescriptor: fileHandle.fileDescriptor,
            maxLength: maxLength,
            operation: "readAvailableData"
        )
    }

    static func readDataToEndOfFile(
        from fileHandle: FileHandle,
        chunkSize: Int = defaultChunkSize
    ) -> Result<Data, ProcessPipeReadError> {
        var data = Data()
        while true {
            switch readOnce(
                fileDescriptor: fileHandle.fileDescriptor,
                maxLength: chunkSize,
                operation: "readDataToEndOfFile"
            ) {
            case .success(let chunk):
                guard !chunk.isEmpty else { return .success(data) }
                data.append(chunk)
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    static func readDataToEndOfFileOrEmpty(from fileHandle: FileHandle) -> Data {
        switch readDataToEndOfFile(from: fileHandle) {
        case .success(let data):
            return data
        case .failure:
            return Data()
        }
    }

    static func readAvailableDataOrEmpty(from fileHandle: FileHandle) -> Data {
        switch readAvailableData(from: fileHandle) {
        case .success(let data):
            return data
        case .failure:
            fileHandle.readabilityHandler = nil
            return Data()
        }
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
}
