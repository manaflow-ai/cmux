public import Foundation

/// One app that can open a file: a row of the Open With submenu.
public struct OpenWithApp: Sendable, Hashable {
    /// The app bundle on disk.
    public let url: URL
    /// The app's bundle identifier; nil for a bundle without one (then rows dedupe by path).
    public let bundleID: String?
    /// The name the row shows (the app's display name).
    public let name: String
    /// The system's default app for the file (the first row, marked "(default)").
    public var isDefault: Bool

    /// An app row.
    ///
    /// - Parameters:
    ///   - url: the app bundle.
    ///   - bundleID: its bundle identifier, when it has one.
    ///   - name: the display name.
    ///   - isDefault: whether it is the file's default app; ``OpenWithList`` sets it.
    public init(url: URL, bundleID: String?, name: String, isDefault: Bool = false) {
        self.url = url
        self.bundleID = bundleID
        self.name = name
        self.isDefault = isDefault
    }

    /// The key two copies of one app share.
    var identity: String { bundleID?.lowercased() ?? url.standardizedFileURL.path }
}
