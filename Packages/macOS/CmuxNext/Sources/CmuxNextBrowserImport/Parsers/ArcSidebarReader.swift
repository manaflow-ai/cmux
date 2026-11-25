public import Foundation

/// Reads Arc's `StorableSidebar.json`. Arc keeps its bookmarks in the
/// sidebar, not in Chromium's `Bookmarks` file: each space has a pinned
/// container (tabs and nested folders, called lists), and each profile has
/// a Favorites row (top apps). Unpinned tabs are open tabs, not bookmarks.
///
/// Shape (`sidebar.containers[1]`): `items` and `spaces` are flat arrays
/// that alternate an id string and the object; items link through
/// `parentID` / `childrenIds`. A space names its profile as
/// `{"default": true}` or `{"custom": {"_0": {"directoryBasename": "Profile 1"}}}`
/// and lists `containerIDs` as `["unpinned", id, "pinned", id]`;
/// `topAppsContainerIDs` alternates a profile and a container id the same way.
public struct ArcSidebarReader {
    /// Creates a reader for Arc's sidebar.
    public init() {}

    public enum Failure: Error { case notSidebar }

    /// Bookmarks of the profile in folder `profileDirectory` ("Default",
    /// "Profile 1"): Favorites first, then each space's pinned items under
    /// the space's name.
    public func parse(_ data: Data, profileDirectory: String) throws -> [ImportedBookmark] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [[String: Any]] else { throw Failure.notSidebar }
        guard let container = containers.first(where: { $0["items"] != nil || $0["spaces"] != nil }) else { return [] }
        let items = Dictionary(objects(container["items"]).compactMap { item in (item["id"] as? String).map { ($0, item) } },
                               uniquingKeysWith: { first, _ in first })
        var result: [ImportedBookmark] = []
        // Favorites: the profile's top-apps container.
        for (profile, id) in pairs(container["topAppsContainerIDs"]) where profile == profileDirectory {
            walk(id, items: items, path: ["Favorites"], depth: 0, into: &result)
        }
        for space in objects(container["spaces"]) where Self.profileDirectory(space["profile"]) == profileDirectory {
            let title = (space["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Space"
            let ids = space["containerIDs"] as? [Any] ?? []
            for (index, value) in ids.enumerated() where (value as? String) == "pinned" && index + 1 < ids.count {
                guard let pinned = ids[index + 1] as? String else { continue }
                walk(pinned, items: items, path: [title], depth: 0, into: &result)
            }
        }
        return result
    }

    private func walk(_ id: String, items: [String: [String: Any]], path: [String], depth: Int, into result: inout [ImportedBookmark]) {
        guard depth < 64, let node = items[id] else { return }
        for childID in node["childrenIds"] as? [String] ?? [] {
            guard let child = items[childID] else { continue }
            let data = child["data"] as? [String: Any] ?? [:]
            if let tab = data["tab"] as? [String: Any] {
                guard let text = tab["savedURL"] as? String, let url = ImportableURL.parse(text) else { continue }
                let title = [child["title"] as? String, tab["savedTitle"] as? String].compactMap { $0 }.first { !$0.isEmpty } ?? text
                let created = (child["createdAt"] as? Double).flatMap(BrowserTime().cocoa)
                result.append(ImportedBookmark(title: title, url: url, folderPath: path, dateAdded: created))
            } else if data["list"] != nil || data["itemContainer"] != nil {
                let name = (child["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                walk(childID, items: items, path: name.map { path + [$0] } ?? path, depth: depth + 1, into: &result)
            }
        }
    }

    /// The objects of an alternating id/object array.
    private func objects(_ value: Any?) -> [[String: Any]] {
        (value as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    /// (profile directory, container id) pairs of `topAppsContainerIDs`.
    private func pairs(_ value: Any?) -> [(String, String)] {
        let list = value as? [Any] ?? []
        var result: [(String, String)] = []
        var index = 0
        while index + 1 < list.count { // wakeup-allow: bounded by the array length
            if let profile = Self.profileDirectory(list[index]), let id = list[index + 1] as? String {
                result.append((profile, id))
                index += 2
            } else {
                index += 1
            }
        }
        return result
    }

    /// "Default" for `{"default": true}`, the folder name for a custom profile.
    static func profileDirectory(_ value: Any?) -> String? {
        guard let profile = value as? [String: Any] else { return nil }
        if profile["default"] != nil { return "Default" }
        if let custom = profile["custom"] as? [String: Any], let inner = custom["_0"] as? [String: Any],
           let folder = inner["directoryBasename"] as? String, !folder.isEmpty {
            return folder
        }
        return nil
    }
}
