package import Foundation

/// One named extended attribute of files (MARKDOWN-TABLE-WIDTHS-DESIGN.md): the seam tests replace
/// to act as a volume that refuses extended attributes.
nonisolated package protocol ExtendedAttributeAccess: Sendable {
    /// The attribute's bytes on `path`; nil when the file has none (or it cannot be read).
    func read(_ name: String, at path: String) -> Data?
    /// Writes the attribute; false when the file or its volume refuses it.
    func write(_ name: String, _ value: Data, at path: String) -> Bool
    /// Removes the attribute (absent counts as removed); false when refused.
    func remove(_ name: String, at path: String) -> Bool
}
