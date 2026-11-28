import Foundation

/// Client-only presentation of the owner's feed. Filtering never marks an
/// item read or changes the owner-confirmed selection.
struct FeedInboxFilter: Equatable {
    enum Connection: String, CaseIterable { case feed, github }
    enum Category: String, CaseIterable { case all, unread, needsYou, notices }

    var connection: Connection = .feed
    var category: Category = .all
    var query = ""

    func items(from items: [FeedItem]) -> [FeedItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in
            if connection == .github && !Self.isGitHub(item) { return false }
            switch category {
            case .all: break
            case .unread: if !item.isUnread { return false }
            case .needsYou: if !item.isOpenRequest { return false }
            case .notices: if item.isRequest { return false }
            }
            let searchable = [item.title, item.body, item.poster.displayLabel, item.context.url?.absoluteString ?? ""].joined(separator: " ")
            return terms.allSatisfy { searchable.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    static func isGitHub(_ item: FeedItem) -> Bool {
        // A cloud session is currently coerced to poster kind `user`; the
        // provider namespace and label remain stable until the local owner
        // adapter is available.
        item.dedupeKey?.hasPrefix("github:") == true || item.poster.label == "GitHub"
    }

    func selectedItem(_ selection: String?, groups: FeedInboxGroups) -> FeedItem? {
        guard let selection else { return nil }
        return groups.all.lazy.flatMap(\.members).first { $0.id == selection }
    }
}
