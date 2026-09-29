/// Reduces an externally supplied attachment name (a pasteboard provider's
/// `suggestedName`, a picked file's name) to one safe path component.
///
/// The provider controls that string, so it may carry `/` separators or `..`
/// components. Only the final component is kept, and names that do not denote
/// a file inside a directory (`""`, `.`, `..`, embedded NUL, over 255 UTF-8
/// bytes) are rejected so the caller falls back to a generated name.
public enum MobileAttachmentFileName {
    /// APFS and HFS+ cap one path component at 255 bytes.
    static let maxComponentBytes = 255

    public static func sanitized(_ raw: String) -> String? {
        guard !raw.contains("\u{0}") else { return nil }
        guard let last = raw.split(separator: "/", omittingEmptySubsequences: true).last else {
            return nil
        }
        let name = String(last)
        guard name != ".", name != "..", name.utf8.count <= maxComponentBytes else {
            return nil
        }
        return name
    }
}
