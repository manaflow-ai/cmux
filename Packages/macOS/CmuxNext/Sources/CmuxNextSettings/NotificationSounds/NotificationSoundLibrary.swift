import CmuxNextCompat
public import Foundation

/// The sounds a notification can play, by name: the person's own that cmux keeps (``userDirectory``,
/// a `Sounds` folder in this build's own folder under cmux's Application Support, where
/// Custom Sound… and Import Sound… copy a file), then `~/Library/Sounds`, the Mac's
/// (`/Library/Sounds`) and the system's (`/System/Library/Sounds`). `NSSound(named:)` searches the
/// last three; the player loads the first by path (``customFiles()``).
///
/// Every method reads the disk: call it off the main thread. Tests pass temporary folders:
///
/// ```swift
/// let library = NotificationSoundLibrary(userDirectory: tmp.appending(path: "Sounds"), otherDirectories: [])
/// let name = try library.importSound(from: tmp.appending(path: "Chime.wav"))  // "Chime"
/// ```
public nonisolated struct NotificationSoundLibrary: Sendable {
    /// Where imports go; searched first.
    public let userDirectory: URL
    /// Every folder searched, the user's first.
    public let directories: [URL]

    /// - Parameters:
    ///   - userDirectory: Where imports go (``defaultUserDirectory``); tests pass a temporary folder.
    ///   - otherDirectories: The other folders searched, in order.
    public init(userDirectory: URL = Self.defaultUserDirectory,
                otherDirectories: [URL] = [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Sounds", directoryHint: .isDirectory),
                                           URL(fileURLWithPath: "/Library/Sounds", isDirectory: true),
                                           URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)]) {
        self.userDirectory = userDirectory
        directories = [userDirectory] + otherDirectories
    }

    /// `Sounds` in this bundle's own folder under cmux-next's Application Support
    /// (``NextSupport/bundleFolder(bundleID:)``): a dev build keeps its own.
    public static var defaultUserDirectory: URL {
        NextSupport().bundleFolder(bundleID: Bundle.main.bundleIdentifier).appending(path: "Sounds", directoryHint: .isDirectory)
    }

    /// The audio file extensions `NSSound` plays.
    public static let extensions: Set<String> = ["aiff", "aif", "aifc", "caf", "wav", "mp3", "m4a"]

    /// Every sound name, without its extension, once each, sorted.
    public func names() -> [String] {
        var seen = Set<String>()
        for directory in directories {
            let files = (try? FileManager.checked.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where Self.extensions.contains(file.pathExtension.lowercased()) {
                seen.insert(file.deletingPathExtension().lastPathComponent)
            }
        }
        return seen.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The sounds in ``userDirectory`` by name, each to its file: `NSSound(named:)` does not search
    /// it, so the player loads these by path.
    public func customFiles() -> [String: URL] {
        let files = (try? FileManager.checked.contentsOfDirectory(at: userDirectory, includingPropertiesForKeys: nil)) ?? []
        var found: [String: URL] = [:]
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where Self.extensions.contains(file.pathExtension.lowercased()) {
            let name = file.deletingPathExtension().lastPathComponent
            if found[name] == nil { found[name] = file }
        }
        return found
    }

    /// A file the library refuses to import.
    public struct ImportRefusal: Error, Equatable {
        /// What the person reads (localized).
        public let message: String
    }

    /// Copies `file` into ``userDirectory`` and returns its sound name. The same file imported
    /// again keeps its name; another file with a name already taken (here or in a system folder,
    /// which the import would shadow) gets "Name 2", "Name 3"….
    ///
    /// - Parameter file: An audio file (``extensions``).
    /// - Returns: The name cmux.json stores.
    /// - Throws: ``ImportRefusal`` for a file `NSSound` cannot play or a failed copy.
    public func importSound(from file: URL) throws(ImportRefusal) -> String {
        let ext = file.pathExtension.lowercased()
        guard Self.extensions.contains(ext) else {
            throw ImportRefusal(message: NotificationSoundStrings.unsupportedFile(file.lastPathComponent))
        }
        let files = FileManager.checked
        let base = file.deletingPathExtension().lastPathComponent
        do {
            try files.createDirectory(at: userDirectory, withIntermediateDirectories: true)
            for index in 1...999 {
                let name = index == 1 ? base : "\(base) \(index)"
                let target = userDirectory.appending(path: "\(name).\(ext)", directoryHint: .notDirectory)
                if files.fileExists(atPath: target.path) {
                    if files.contentsEqual(atPath: target.path, andPath: file.path) { return name }
                    continue
                }
                // A name is one file: another extension kept here, or a sound another folder plays, takes it.
                if directories.contains(where: { Self.hasSound(named: name, in: $0) }) { continue }
                try files.copyItem(at: file, to: target)
                return name
            }
        } catch {
            throw ImportRefusal(message: NotificationSoundStrings.importFailed(file.lastPathComponent))
        }
        throw ImportRefusal(message: NotificationSoundStrings.importFailed(file.lastPathComponent))
    }

    private static func hasSound(named name: String, in directory: URL) -> Bool {
        extensions.contains { FileManager.checked.fileExists(atPath: directory.appending(path: "\(name).\($0)").path) }
    }
}
