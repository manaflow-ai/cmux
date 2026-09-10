import Darwin
import Foundation

/// Reads CLI input through POSIX descriptors without exceeding a caller-owned byte bound.
struct SudoBoundedInputReader {
    func readStandardInput(maximumBytes: Int) throws -> Data {
        try read(descriptor: STDIN_FILENO, maximumBytes: maximumBytes)
    }

    func readRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.open(errno) }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw Failure.status(errno) }
        guard status.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegularFile }
        guard status.st_size >= 0,
              status.st_size <= off_t(maximumBytes) else {
            throw Failure.tooLarge
        }
        return try read(descriptor: descriptor, maximumBytes: maximumBytes)
    }

    func read(descriptor: Int32, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else { throw Failure.invalidLimit }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1_024))
        var buffer = [UInt8](repeating: 0, count: min(maximumBytes, 64 * 1_024))
        if buffer.isEmpty { return data }

        while data.count < maximumBytes {
            let requestedCount = min(buffer.count, maximumBytes - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requestedCount)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return data
            } else if errno == EINTR {
                continue
            } else {
                throw Failure.read(errno)
            }
        }
        return data
    }

    enum Failure: Error, Equatable {
        case invalidLimit
        case open(Int32)
        case status(Int32)
        case notRegularFile
        case tooLarge
        case read(Int32)
    }
}
