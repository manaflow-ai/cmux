public import Foundation

/// Reads a Chromium user data dir's profile list from `Local State`
/// (`profile.info_cache`, ordered by `profile.profiles_order`), falling back
/// to folders that hold a `Preferences` file.
public struct ChromiumProfileList {
    private let fileManager: FileManager

    /// Creates a reader with the filesystem used to discover Chromium profiles.
    ///
    /// - Parameter fileManager: Filesystem access for discovery.
    public init(fileManager: FileManager = FileManager()) {
        self.fileManager = fileManager
    }

    public struct Entry: Sendable, Equatable {
        public var directoryName: String
        public var displayName: String
        /// The account picture the browser saved in the profile folder
        /// (`gaia_picture_file_name`: "Google Profile Picture.png" in Chrome,
        /// "Edge Profile Picture.png" in Edge), when it has one.
        public var avatarFileName: String? = nil
    }

    public func entries(in userDataDirectory: URL) -> [Entry] {
        let localState = userDataDirectory.appending(path: "Local State")
        var entries: [Entry] = []
        if let data = fileManager.contents(atPath: localState.path),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = root["profile"] as? [String: Any],
           let cache = profile["info_cache"] as? [String: Any] {
            let order = (profile["profiles_order"] as? [String]) ?? []
            let names = cache.keys.sorted { lhs, rhs in
                let (li, ri) = (order.firstIndex(of: lhs) ?? Int.max, order.firstIndex(of: rhs) ?? Int.max)
                return li != ri ? li < ri : sortKey(lhs) < sortKey(rhs)
            }
            for directory in names {
                let info = cache[directory] as? [String: Any]
                let name = (info?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? directory
                let picture = (info?["gaia_picture_file_name"] as? String).flatMap { $0.isEmpty || $0.contains("/") ? nil : $0 }
                entries.append(Entry(directoryName: directory, displayName: name, avatarFileName: picture))
            }
        }
        // Profiles on disk that Local State does not list (or no Local State).
        let listed = Set(entries.map(\.directoryName))
        let folders = (try? fileManager.contentsOfDirectory(atPath: userDataDirectory.path)) ?? []
        for folder in folders.sorted(by: { sortKey($0) < sortKey($1) }) where !listed.contains(folder) {
            guard folder == "Default" || folder.hasPrefix("Profile ") else { continue }
            let preferences = userDataDirectory.appending(path: folder).appending(path: "Preferences")
            guard fileManager.fileExists(atPath: preferences.path) else { continue }
            entries.append(Entry(directoryName: folder, displayName: folder))
        }
        return entries.filter { fileManager.fileExists(atPath: userDataDirectory.appending(path: $0.directoryName).path) }
    }

    /// "Default" first, then "Profile 2" before "Profile 10".
    private func sortKey(_ name: String) -> (Int, String) {
        if name == "Default" { return (0, "") }
        if name.hasPrefix("Profile "), let number = Int(name.dropFirst(8)) { return (number + 1, "") }
        return (Int.max, name)
    }
}
