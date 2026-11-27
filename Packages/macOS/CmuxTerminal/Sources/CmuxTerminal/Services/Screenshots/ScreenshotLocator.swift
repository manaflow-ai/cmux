public import Foundation
internal import Darwin

/// Finds the newest macOS screenshot in the folder screenshots are saved to.
///
/// The folder is the `location` preference in `com.apple.screencapture` (set
/// in the Screenshot app's Options menu). An unset, relative, or missing
/// location falls back to `~/Desktop`, the macOS default.
///
/// A file counts as a screenshot when it is a visible, regular image file
/// directly inside that folder and either carries the `kMDItemIsScreenCapture`
/// metadata macOS writes on screenshots, or is named like one ("Screenshot …",
/// "Screen Shot …", or the custom `name` preference). Other images in the
/// folder are ignored, so a downloaded picture on the Desktop is never taken
/// for a screenshot. Screen recordings (`.mov`) are not images and never match.
///
/// The locator only reads: it lists one directory, reads file metadata and
/// extended attributes, and reads preferences through its
/// ``ScreenCapturePreferenceReading``.
///
/// ```swift
/// let locator = ScreenshotLocator(
///     preferences: SystemScreenCapturePreferences(),
///     fileManager: .default,
///     homeDirectory: FileManager.default.homeDirectoryForCurrentUser
/// )
/// let newest = locator.newestScreenshot()
/// ```
public struct ScreenshotLocator {
    /// The extended attribute that stores Spotlight's `kMDItemIsScreenCapture` flag.
    static let screenCaptureAttributeName = "com.apple.metadata:kMDItemIsScreenCapture"

    /// Image extensions screenshots are saved with. The `type` preference adds its own.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp",
    ]

    /// English screenshot name prefixes: current macOS, then macOS 10.14 and earlier.
    static let defaultNamePrefixes = ["Screenshot", "Screen Shot"]

    private let preferences: any ScreenCapturePreferenceReading
    private let fileManager: FileManager
    private let homeDirectory: URL

    /// Creates a locator.
    ///
    /// - Parameters:
    ///   - preferences: Source of the `location`, `name` and `type` screenshot preferences.
    ///   - fileManager: The file manager used to list the folder.
    ///   - homeDirectory: The directory `~` expands to, and the parent of the
    ///     `Desktop` fallback.
    public init(
        preferences: any ScreenCapturePreferenceReading,
        fileManager: FileManager,
        homeDirectory: URL
    ) {
        self.preferences = preferences
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    /// The folder new screenshots are saved to.
    ///
    /// - Returns: The `location` preference with `~` expanded when it names an
    ///   existing directory by absolute or `~` path; otherwise `~/Desktop`.
    public func screenshotDirectory() -> URL {
        let fallback = homeDirectory.appendingPathComponent("Desktop", isDirectory: true)
        guard let raw = preferences.string(forKey: "location")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return fallback
        }
        let path: String
        if raw == "~" {
            path = homeDirectory.path
        } else if raw.hasPrefix("~/") {
            path = homeDirectory.appendingPathComponent(String(raw.dropFirst(2))).path
        } else if raw.hasPrefix("/") {
            path = raw
        } else {
            return fallback
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return fallback
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// The most recently created screenshot in ``screenshotDirectory()``.
    ///
    /// Files are ordered by creation date (modification date when the file
    /// system has none), newest first, with the file name breaking ties.
    ///
    /// - Returns: The screenshot's file URL, or nil when the folder cannot be
    ///   read or holds no screenshot.
    public func newestScreenshot() -> URL? {
        let directory = screenshotDirectory()
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
        ) else {
            return nil
        }
        let extensions = acceptedExtensions()
        let keySet = Set(keys)
        let candidates: [(url: URL, date: Date)] = entries.compactMap { url in
            guard extensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keySet),
                  values.isRegularFile == true else {
                return nil
            }
            return (url: url, date: values.creationDate ?? values.contentModificationDate ?? .distantPast)
        }
        let newestFirst = candidates.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }
        let prefixes = namePrefixes()
        return newestFirst.first { isScreenshot($0.url, namePrefixes: prefixes) }?.url
    }

    private func acceptedExtensions() -> Set<String> {
        var extensions = Self.imageExtensions
        if let type = preferences.string(forKey: "type")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !type.isEmpty,
            type.allSatisfy({ $0.isLetter || $0.isNumber }) {
            extensions.insert(type)
        }
        return extensions
    }

    private func namePrefixes() -> [String] {
        var prefixes = Self.defaultNamePrefixes
        if let custom = preferences.string(forKey: "name")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !custom.isEmpty {
            prefixes.insert(custom, at: 0)
        }
        return prefixes
    }

    private func isScreenshot(_ url: URL, namePrefixes: [String]) -> Bool {
        if hasScreenCaptureMarker(url) { return true }
        // "Screenshot 2026-09-27 at 10.00.00.png", or "Screenshot.png" and
        // "Screenshot 2.png" when the date is turned off.
        let stem = url.deletingPathExtension().lastPathComponent
        return namePrefixes.contains { prefix in
            stem == prefix || stem.hasPrefix(prefix + " ")
        }
    }

    /// Whether `url` carries `kMDItemIsScreenCapture = true`, which macOS
    /// writes on every screenshot whatever its localized file name.
    func hasScreenCaptureMarker(_ url: URL) -> Bool {
        let path = url.path
        let name = Self.screenCaptureAttributeName
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        // The value is a tiny binary plist; anything large is not this flag.
        guard size > 0, size <= 4_096 else { return false }
        var bytes = [UInt8](repeating: 0, count: size)
        let read = bytes.withUnsafeMutableBytes { buffer in
            getxattr(path, name, buffer.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
        guard read > 0 else { return false }
        let data = Data(bytes[..<read])
        guard let value = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else {
            return false
        }
        return (value as? Bool) == true
    }
}
