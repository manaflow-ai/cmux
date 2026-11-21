import Darwin
public import Foundation

/// ``ExtendedAttributeAccess`` through getxattr(2), setxattr(2) and removexattr(2).
public nonisolated struct DarwinExtendedAttributes: ExtendedAttributeAccess {
    /// The largest value read back; a bigger one is not ours.
    public static let readLimit = 64 * 1024

    /// Makes the accessor; it holds no state.
    public init() {}

    /// The attribute `name`'s bytes on `path`; nil when absent, unreadable or over ``readLimit``.
    public func read(_ name: String, at path: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0, size <= Self.readLimit else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        return read == size ? data : nil
    }

    /// Writes `value` as attribute `name` on `path`; false when refused.
    public func write(_ name: String, _ value: Data, at path: String) -> Bool {
        value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, 0) } == 0
    }

    /// Removes attribute `name` from `path` (absent counts as removed); false when refused.
    public func remove(_ name: String, at path: String) -> Bool {
        removexattr(path, name, 0) == 0 || errno == ENOATTR
    }
}
