import Foundation

/// The group hover card's localized texts (Resources/Localizable.xcstrings).
nonisolated struct GroupHoverCardStrings {
    static func count(_ kind: GroupHoverCardSummary.Kind, _ count: Int) -> String {
        switch kind {
        case .workspaceGroup:
            String(format: String(localized: "groupCard.workspaces", defaultValue: "Workspaces: %d", bundle: .l10n), count)
        case .tabGroup:
            String(format: String(localized: "groupCard.tabs", defaultValue: "Tabs: %d", bundle: .l10n), count)
        }
    }

    static func working(_ count: Int) -> String {
        String(format: String(localized: "groupCard.working", defaultValue: "Working: %d", bundle: .l10n), count)
    }

    static func waiting(_ count: Int) -> String {
        String(format: String(localized: "groupCard.waiting", defaultValue: "Waiting: %d", bundle: .l10n), count)
    }

    static func failed(_ count: Int) -> String {
        String(format: String(localized: "groupCard.failed", defaultValue: "Failed: %d", bundle: .l10n), count)
    }

    static func unread(_ count: Int) -> String {
        String(format: String(localized: "groupCard.unread", defaultValue: "Unread: %d", bundle: .l10n), count)
    }

    static var allIdle: String { String(localized: "groupCard.allIdle", defaultValue: "All idle", bundle: .l10n) }

    static var justNow: String { String(localized: "groupCard.justNow", defaultValue: "Just now", bundle: .l10n) }

    static func more(_ count: Int) -> String {
        String(format: String(localized: "groupCard.more", defaultValue: "+%d more", bundle: .l10n), count)
    }

    static func latest(_ title: String, age: String) -> String {
        String(format: String(localized: "groupCard.latest", defaultValue: "Latest: %1$@ \u{00B7} %2$@", bundle: .l10n), title, age)
    }

    static func branches(_ list: String) -> String {
        String(format: String(localized: "groupCard.branches", defaultValue: "Branches: %@", bundle: .l10n), list)
    }

    static func ports(_ list: String) -> String {
        String(format: String(localized: "groupCard.ports", defaultValue: "Ports: %@", bundle: .l10n), list)
    }
}
