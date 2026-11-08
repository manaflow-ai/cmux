import Darwin
import Foundation

/// Reads the anonymous reviewed-script capability inherited by the hidden runner.
struct SudoReviewedScriptReader: Sendable {
    private let descriptor: Int32

    init(descriptor: Int32 = STDIN_FILENO) {
        self.descriptor = descriptor
    }

    func read() throws -> Data {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 0,
              status.st_size >= 0,
              status.st_size <= off_t(SudoReviewedScriptCapability.maximumBytes) else {
            throw Failure.invalidCapability
        }
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw Failure.read(errno)
        }

        var data = Data(count: Int(status.st_size))
        var offset = 0
        while offset < data.count {
            let remainingCount = data.count - offset
            let count = data.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    remainingCount
                )
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw Failure.read(count == 0 ? EIO : errno)
            }
        }
        return data
    }

    private enum Failure: Error {
        case invalidCapability
        case read(Int32)
    }
}
