import CmuxMobileShellModel
import Foundation

/// One notification per native list cell, including expanded history.
struct NotificationFeedListRow: Identifiable, Equatable, Sendable {
    let model: NotificationFeedRowModel
    let context: NotificationFeedRowContext
    let disclosure: NotificationFeedDisclosure?

    var id: MobileNotificationFeedItemID { model.id }
}

struct NotificationFeedDisclosure: Equatable, Sendable {
    let groupID: MobileNotificationFeedItemID
    let count: Int
    let isExpanded: Bool
}

/// Only inherited metadata changes when an ordinary row becomes a child.
struct NotificationFeedRowContext: Equatable, Sendable {
    var isNested = false
    var hidesHeadline = false
    var hidesSource = false
    var hidesComputer = false

    static let standalone = Self()
}

struct NotificationFeedActivityGroup: Identifiable, Equatable, Sendable {
    var items: [NotificationFeedRowModel]

    /// The oldest retained event stays the anchor when newer updates arrive.
    var id: MobileNotificationFeedItemID { items[items.count - 1].id }

    func accepts(_ model: NotificationFeedRowModel) -> Bool {
        let latest = items[0].item
        let item = model.item
        return latest.macDeviceID == item.macDeviceID
            && latest.macInstanceTag == item.macInstanceTag
            && latest.remoteWorkspaceID == item.remoteWorkspaceID
            && latest.remoteSurfaceID == item.remoteSurfaceID
            && latest.createdAt.timeIntervalSince(item.createdAt) <= 2 * 60 * 60
    }

    func rows(isExpanded: Bool) -> [NotificationFeedListRow] {
        let latest = items[0]
        let disclosure = items.count > 1
            ? NotificationFeedDisclosure(groupID: id, count: items.count, isExpanded: isExpanded)
            : nil
        var result = [NotificationFeedListRow(
            model: latest,
            context: .standalone,
            disclosure: disclosure
        )]
        if isExpanded {
            result += items.dropFirst().map { model in
                NotificationFeedListRow(
                    model: model,
                    context: model.presentation.nestedContext(under: latest.presentation),
                    disclosure: nil
                )
            }
        }
        return result
    }

    static func build(from items: [NotificationFeedRowModel]) -> [Self] {
        var groups: [Self] = []
        for item in items {
            if let index = groups.indices.last, groups[index].accepts(item) {
                groups[index].items.append(item)
            } else {
                groups.append(Self(items: [item]))
            }
        }
        return groups
    }
}
