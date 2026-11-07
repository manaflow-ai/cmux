public import Foundation

/// A flat imported bookmark: title, URL and its folder path from the source's root (the shape
/// `CmuxNextBrowserImport` reads from every browser); the home daemon builds the folders.
public struct BookmarkImportItem: Sendable, Hashable {
    public var title: String
    public var url: URL
    public var folderPath: [String]
    public var created: Date?

    public init(title: String, url: URL, folderPath: [String], created: Date? = nil) {
        self.title = title
        self.url = url
        self.folderPath = folderPath
        self.created = created
    }
}
