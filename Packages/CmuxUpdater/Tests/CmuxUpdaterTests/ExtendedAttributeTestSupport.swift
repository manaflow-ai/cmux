import Darwin
import Foundation

func setExtendedAttribute(_ name: String, value: String, at url: URL) throws {
    let bytes = Array(value.utf8)
    let result = bytes.withUnsafeBufferPointer { buffer in
        setxattr(url.path, name, buffer.baseAddress, buffer.count, 0, 0)
    }
    if result != 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

func hasExtendedAttribute(_ name: String, at url: URL) -> Bool {
    getxattr(url.path, name, nil, 0, 0, 0) >= 0
}
