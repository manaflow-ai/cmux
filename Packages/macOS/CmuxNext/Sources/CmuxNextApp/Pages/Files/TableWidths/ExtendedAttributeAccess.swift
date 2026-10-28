import Darwin
import Foundation

/// One named extended attribute of files (MARKDOWN-TABLE-WIDTHS-DESIGN.md): the seam tests replace
/// to act as a volume that refuses extended attributes.
nonisolated protocol ExtendedAttributeAccess: Sendable {
    /// The attribute's bytes on `path`; nil when the file has none (or it cannot be read).
    func read(_ name: String, at path: String) -> Data?
    /// Writes the attribute; false when the file or its volume refuses it.
    func write(_ name: String, _ value: Data, at path: String) -> Bool
    /// Removes the attribute (absent counts as removed); false when refused.
    func remove(_ name: String, at path: String) -> Bool
}

/// ``ExtendedAttributeAccess`` through getxattr(2), setxattr(2) and removexattr(2).
nonisolated struct DarwinExtendedAttributes: ExtendedAttributeAccess {
    /// The largest value read back; a bigger one is not ours.
    static let readLimit = 64 * 1024

    func read(_ name: String, at path: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0, size <= Self.readLimit else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        return read == size ? data : nil
    }

    func write(_ name: String, _ value: Data, at path: String) -> Bool {
        value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, 0) } == 0
    }

    func remove(_ name: String, at path: String) -> Bool {
        removexattr(path, name, 0) == 0 || errno == ENOATTR
    }
}
