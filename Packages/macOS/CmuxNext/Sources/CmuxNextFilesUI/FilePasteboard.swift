import AppKit

/// File URLs on a pasteboard: what Copy writes, Paste and drops read.
///
/// Writes plain file URLs (what Finder, Terminal and chat composers accept)
/// and a newline-joined path string for text fields.
nonisolated enum FilePasteboard {
    /// The file URLs on `pasteboard`, in order.
    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    /// Puts `urls` on `pasteboard` (Copy).
    static func write(_ urls: [URL], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    /// Puts the paths of `urls` on `pasteboard` as text (Copy as Pathname).
    static func writePaths(_ urls: [URL], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }
}
