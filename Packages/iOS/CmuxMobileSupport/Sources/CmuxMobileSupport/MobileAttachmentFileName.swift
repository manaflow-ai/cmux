/// One safe path component derived from an externally supplied attachment
/// name (a pasteboard provider's `suggestedName`, a picked file's name).
///
/// The provider controls that string, so it may carry `/` separators or `..`
/// components. Only the final component is kept, and names that do not denote
/// a file inside a directory (`""`, `.`, `..`, embedded NUL, over 255 UTF-8
/// bytes) fail to initialize so the caller falls back to a generated name.
public struct MobileAttachmentFileName: Hashable, Sendable {
    /// APFS and HFS+ cap one path component at 255 bytes.
    static let maxComponentBytes = 255

    /// The single path component, safe to append to a directory URL.
    public let value: String

    /// Fails when `raw` has no usable final component.
    public init?(_ raw: String) {
        guard !raw.contains("\u{0}") else { return nil }
        guard let last = raw.split(separator: "/", omittingEmptySubsequences: true).last else {
            return nil
        }
        let name = String(last)
        guard name != ".", name != "..", name.utf8.count <= Self.maxComponentBytes else {
            return nil
        }
        value = name
    }
}
