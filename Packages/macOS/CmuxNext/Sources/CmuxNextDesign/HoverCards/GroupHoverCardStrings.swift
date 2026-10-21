import Foundation

/// The group hover card's localized texts (Resources/Localizable.xcstrings).
nonisolated struct GroupHoverCardStrings {
    static func count(_ kind: GroupHoverCardSummary.Kind, _ count: Int) -> String {
        switch kind {
        case .workspaceGroup:
            String(format: String(localized: "groupCard.workspaces", defaultValue: "Workspaces: %d", bundle: .module), count)
        case .tabGroup:
            String(format: String(localized: "groupCard.tabs", defaultValue: "Tabs: %d", bundle: .module), count)
        }
    }

    static func working(_ count: Int) -> String {
        String(format: String(localized: "groupCard.working", defaultValue: "Working: %d", bundle: .module), count)
    }

    static func waiting(_ count: Int) -> String {
        String(format: String(localized: "groupCard.waiting", defaultValue: "Waiting: %d", bundle: .module), count)
    }

    static func failed(_ count: Int) -> String {
        String(format: String(localized: "groupCard.failed", defaultValue: "Failed: %d", bundle: .module), count)
    }

    static func unread(_ count: Int) -> String {
        String(format: String(localized: "groupCard.unread", defaultValue: "Unread: %d", bundle: .module), count)
    }

    static var allIdle: String { String(localized: "groupCard.allIdle", defaultValue: "All idle", bundle: .module) }

    static var justNow: String { String(localized: "groupCard.justNow", defaultValue: "Just now", bundle: .module) }

    static func more(_ count: Int) -> String {
        String(format: String(localized: "groupCard.more", defaultValue: "+%d more", bundle: .module), count)
    }

    static func latest(_ title: String, age: String) -> String {
        String(format: String(localized: "groupCard.latest", defaultValue: "Latest: %1$@ \u{00B7} %2$@", bundle: .module), title, age)
    }

    static func branches(_ list: String) -> String {
        String(format: String(localized: "groupCard.branches", defaultValue: "Branches: %@", bundle: .module), list)
    }

    static func ports(_ list: String) -> String {
        String(format: String(localized: "groupCard.ports", defaultValue: "Ports: %@", bundle: .module), list)
    }
}
