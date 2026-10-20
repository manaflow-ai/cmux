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
        throw CocoaError(.featureUnsupported)
    }
}
