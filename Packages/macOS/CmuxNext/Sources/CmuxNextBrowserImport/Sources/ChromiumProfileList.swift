public import Foundation
import CmuxNextCompat

/// Reads a Chromium user data dir's profile list from `Local State`
/// (`profile.info_cache`, ordered by `profile.profiles_order`), falling back
/// to folders that hold a `Preferences` file.
public struct ChromiumProfileList {

    /// Creates a reader of Chromium profiles.
    public init() {}

    public struct Entry: Sendable, Equatable {
        public var directoryName: String
        public var displayName: String
        /// The account picture the browser saved in the profile folder
        /// (`gaia_picture_file_name`: "Google Profile Picture.png" in Chrome,
        /// "Edge Profile Picture.png" in Edge), when it has one.
        public var avatarFileName: String? = nil
        /// The profile's color as 0xRRGGBB (the theme seed or highlight
        /// Chrome paints the profile's toolbar and avatar with), when it has one.
        public var color: UInt32?
    }

    /// `Local State` color keys, most specific first: the theme seed (Chrome
    /// 120+), the highlight color, then the default avatar's fill. Chromium
    /// stores each as a signed 32-bit ARGB integer.
    static let colorKeys = ["profile_color_seed", "profile_highlight_color", "default_avatar_fill_color"]

    static func color(_ info: [String: Any]?) -> UInt32? {
        for key in colorKeys {
            guard let number = info?[key] as? NSNumber else { continue }
            return UInt32(truncatingIfNeeded: number.int64Value) & 0xFF_FFFF
        }
        return nil
    }

    public func entries(in userDataDirectory: URL) -> [Entry] {
        let localState = userDataDirectory.appending(path: "Local State")
        var entries: [Entry] = []
        if let data = FileManager.checked.contents(atPath: localState.path),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = root["profile"] as? [String: Any],
           let cache: [String: Any] = profile["info_cache"] as? [String: Any] {
            let order = (profile["profiles_order"] as? [String]) ?? []
            let names = cache.keys.sorted { lhs, rhs in
                let (li, ri) = (order.firstIndex(of: lhs) ?? Int.max, order.firstIndex(of: rhs) ?? Int.max)
                return li != ri ? li < ri : sortKey(lhs) < sortKey(rhs)
            }
            for directory in names {
                let info = cache[directory] as? [String: Any]
                let name = (info?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? directory
                let picture = (info?["gaia_picture_file_name"] as? String).flatMap { $0.isEmpty || $0.contains("/") ? nil : $0 }
                entries.append(Entry(directoryName: directory, displayName: name, avatarFileName: picture, color: Self.color(info)))
            }
        }
        // Profiles on disk that Local State does not list (or no Local State).
        let listed = Set(entries.map(\.directoryName))
        let folders = (try? FileManager.checked.contentsOfDirectory(atPath: userDataDirectory.path)) ?? []
        for folder in folders.sorted(by: { sortKey($0) < sortKey($1) }) where !listed.contains(folder) {
            guard folder == "Default" || folder.hasPrefix("Profile ") else { continue }
            let preferences = userDataDirectory.appending(path: folder).appending(path: "Preferences")
            guard FileManager.checked.fileExists(atPath: preferences.path) else { continue }
            entries.append(Entry(directoryName: folder, displayName: folder))
        }
        return entries.filter { FileManager.checked.fileExists(atPath: userDataDirectory.appending(path: $0.directoryName).path) }
    }

    /// "Default" first, then "Profile 2" before "Profile 10", then other names. The folder's own
    /// number is compared, never offset, so a name like "Profile 9223372036854775807" sorts too.
    private func sortKey(_ name: String) -> (Int, Int, String) {
        if name == "Default" { return (0, 0, "") }
        if name.hasPrefix("Profile "), let number = Int(name.dropFirst(8)) { return (1, number, "") }
        return (2, 0, name)
    }
}
