import Darwin
import Foundation

/// Holds one descriptor-read snapshot of a filesystem item's extended attributes.
struct WorktreeIncludeExtendedAttributes {
    let values: [(name: String, data: Data)]
    let byteCount: Int64

    init(sourceDescriptor: Int32) throws {
        let nameByteCount = flistxattr(sourceDescriptor, nil, 0, 0)
        guard nameByteCount >= 0 else { throw Self.posixError() }
        guard nameByteCount > 0 else {
            values = []
            byteCount = 0
            return
        }

        var nameBytes = [CChar](repeating: 0, count: nameByteCount)
        let readNameByteCount = nameBytes.withUnsafeMutableBufferPointer {
            flistxattr(sourceDescriptor, $0.baseAddress, $0.count, 0)
        }
        guard readNameByteCount == nameByteCount else { throw Self.posixError() }

        var nextValues: [(name: String, data: Data)] = []
        var nextByteCount: Int64 = 0
        var offset = 0
        while offset < readNameByteCount {
            let name = nameBytes.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!.advanced(by: offset))
            }
            guard !name.isEmpty else { throw Self.posixError(EINVAL) }
            offset += name.utf8.count + 1

            let valueSize = name.withCString {
                fgetxattr(sourceDescriptor, $0, nil, 0, 0, 0)
            }
            guard valueSize >= 0 else { throw Self.posixError() }
            var value = Data(count: valueSize)
            let readValueSize = value.withUnsafeMutableBytes { valueBytes in
                name.withCString {
                    fgetxattr(
                        sourceDescriptor,
                        $0,
                        valueBytes.baseAddress,
                        valueBytes.count,
                        0,
                        0
                    )
                }
            }
            guard readValueSize == valueSize else { throw Self.posixError() }
            nextValues.append((name, value))
            nextByteCount += Int64(valueSize)
        }
        values = nextValues
        byteCount = nextByteCount
    }

    func apply(to destinationDescriptor: Int32) throws {
        for value in values {
            let result = value.data.withUnsafeBytes { valueBytes in
                value.name.withCString {
                    fsetxattr(
                        destinationDescriptor,
                        $0,
                        valueBytes.baseAddress,
                        valueBytes.count,
                        0,
                        0
                    )
                }
            }
            guard result == 0 else { throw Self.posixError() }
        }
    }

    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
