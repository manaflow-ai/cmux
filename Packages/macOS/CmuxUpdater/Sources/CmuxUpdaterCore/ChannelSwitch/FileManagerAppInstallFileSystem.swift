public import Foundation

/// ``AppInstallFileSystem`` backed by `FileManager`.
public struct FileManagerAppInstallFileSystem: AppInstallFileSystem {
    /// Creates a file system.
    public init() {}

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func isWritableDirectory(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: directory.path)
    }

    public func createDirectory(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func replaceItem(at original: URL, with replacement: URL) throws {
        _ = try FileManager.default.replaceItemAt(original, withItemAt: replacement)
    }

    public func removeItem(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public func contentsOfDirectory(at directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    /// Reads `CFBundleIdentifier` straight from `Contents/Info.plist`, bypassing `Bundle`'s
    /// per-path cache so a replaced bundle is never reported with stale values.
    public func bundleIdentifier(ofAppAt appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }
}
