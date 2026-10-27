#if !canImport(Darwin)
import Foundation

/// A picked folder as its absolute path in UTF-8: Linux has no bookmarks and no sandbox scope, and a path is
/// what the folder's permissions are checked against on each open.
enum FolderBookmark {
    /// The path of `folder`; nil for a URL that is not a file.
    static func make(_ folder: URL) -> Data? {
        folder.isFileURL ? Data(folder.standardizedFileURL.path.utf8) : nil
    }

    /// The folder `data` names; nil when it is not an absolute path.
    static func resolve(_ data: Data) -> URL? {
        guard let path = String(data: data, encoding: .utf8), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// There is no scope to take.
    static func startAccessing(_ folder: URL) -> Bool { false }

    /// There is no scope to give back.
    static func stopAccessing(_ folder: URL) {}
}
#endif
