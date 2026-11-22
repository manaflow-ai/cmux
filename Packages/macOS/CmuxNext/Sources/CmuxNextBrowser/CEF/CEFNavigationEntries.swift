import Foundation

/// A tab's session history (`cmux_shim_tab_navigation_entries`): entries
/// oldest first and the current index.
nonisolated struct CEFNavigationEntries: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var url: String
        var title: String
    }

    var entries: [Entry]
    var currentIndex: Int

    var current: Entry? { entries.indices.contains(currentIndex) ? entries[currentIndex] : nil }

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["entries"] as? [[String: Any]] else { return nil }
        entries = list.map { Entry(url: $0["url"] as? String ?? "", title: $0["title"] as? String ?? "") }
        currentIndex = object["current"] as? Int ?? -1
    }
}
