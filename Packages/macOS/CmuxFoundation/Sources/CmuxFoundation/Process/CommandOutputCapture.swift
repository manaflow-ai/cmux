import Darwin
import Foundation

/// A bounded snapshot drained from one child-process output descriptor.
struct CommandOutputCapture: Sendable {
    let data: Data
    let limitExceeded: Bool

    init(fileDescriptor: Int32, maximumBytes: Int?) {
        var captured = Data()
        let maximumBytes = maximumBytes.map { max(0, $0) }
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, base, chunkSize)
            }
            if bytesRead > 0 {
                if let maximumBytes {
                    let remaining = maximumBytes - captured.count
                    guard remaining > 0 else {
                        data = captured
                        limitExceeded = true
                        return
                    }
                    captured.append(contentsOf: buffer[0..<min(bytesRead, remaining)])
                    if bytesRead > remaining {
                        data = captured
                        limitExceeded = true
                        return
                    }
                } else {
                    captured.append(contentsOf: buffer[0..<bytesRead])
                }
            } else if bytesRead == 0 {
                break
            } else if errno != EINTR {
                break
            }
        }

        data = captured
        limitExceeded = false
    }
}
