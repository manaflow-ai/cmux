public import Foundation

/// A design mode card as files, for a composer that takes files (the Chief's Home composer): the
/// card's text as `<name>.txt` and the crop as `<name>.png`, in a folder of the caller's.
public nonisolated struct BrowserDesignModeCardFiles: Sendable {
    /// Where the files go; made when missing.
    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    /// Writes `card` (and `png` when there is one) and returns the files in that order.
    /// - Throws: A Cocoa file error when the folder or a file cannot be written.
    public func write(_ card: BrowserDesignModeCard, png: Data?) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = Self.fileStem(card.name)
        let text = folder.appendingPathComponent(stem + ".txt")
        try Data(card.text.utf8).write(to: text, options: .atomic)
        guard let png else { return [text] }
        let image = folder.appendingPathComponent(stem + ".png")
        try png.write(to: image, options: .atomic)
        return [text, image]
    }

    /// The card's name as one file name: no colon (Finder shows it as a slash), no slash.
    package static func fileStem(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "Design" : cleaned).prefix(120))
    }
}
