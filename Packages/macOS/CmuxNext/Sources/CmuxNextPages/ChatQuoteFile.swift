public import Foundation

/// A viewer quote as a file, for a composer that takes files (the Chief's Home composer), the way
/// design mode's highlight cards reach it: the quote's ``ChatQuote/markdown`` as `<title>.txt`.
public nonisolated struct ChatQuoteFile: Sendable {
    /// Where the file goes; made when missing.
    public let folder: URL

    /// A writer into `folder`.
    public init(folder: URL) { self.folder = folder }

    /// Writes `quote` and returns the file.
    /// - Throws: A Cocoa file error when the folder or the file cannot be written.
    public func write(_ quote: ChatQuote) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(Self.fileStem(quote.title) + ".txt")
        try Data(quote.markdown.utf8).write(to: file, options: .atomic)
        return file
    }

    /// The title as one file name: no colon (Finder shows it as a slash), no slash.
    static func fileStem(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "Quote" : cleaned).prefix(120))
    }
}
