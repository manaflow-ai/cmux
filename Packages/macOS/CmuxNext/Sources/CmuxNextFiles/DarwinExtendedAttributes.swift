import Darwin
package import Foundation

/// ``ExtendedAttributeAccess`` through getxattr(2), setxattr(2) and removexattr(2).
nonisolated package struct DarwinExtendedAttributes: ExtendedAttributeAccess {
    /// The largest value read back; a bigger one is not ours.
    package static let readLimit = 64 * 1024

    package init() {}

    package func read(_ name: String, at path: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0, size <= Self.readLimit else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        return read == size ? data : nil
    }

    package func write(_ name: String, _ value: Data, at path: String) -> Bool {
        value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, 0) } == 0
    }

    package func remove(_ name: String, at path: String) -> Bool {
        removexattr(path, name, 0) == 0 || errno == ENOATTR
    }
}
