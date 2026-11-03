import Foundation

/// Text of the Find Work page. Keys live in Resources/MiscHandlers.xcstrings.
struct FindWorkStrings {
    static var title: String { String(localized: "handlers.findWork.title", defaultValue: "Find Work", table: "MiscHandlers", bundle: .module) }
    static var placeholder: String { String(localized: "handlers.findWork.placeholder", defaultValue: "Search workspaces, reviews and assignments", table: "MiscHandlers", bundle: .module) }
    static var needsAttention: String { String(localized: "handlers.findWork.needsAttention", defaultValue: "Needs Attention", table: "MiscHandlers", bundle: .module) }
    static var workspaces: String { String(localized: "handlers.findWork.workspaces", defaultValue: "Workspaces", table: "MiscHandlers", bundle: .module) }
    static var reviewRequests: String { String(localized: "handlers.findWork.reviewRequests", defaultValue: "Review Requests", table: "MiscHandlers", bundle: .module) }
    static var assigned: String { String(localized: "handlers.findWork.assigned", defaultValue: "Assigned to You", table: "MiscHandlers", bundle: .module) }
    static var switchTo: String { String(localized: "handlers.findWork.switchTo", defaultValue: "Switch to Workspace", table: "MiscHandlers", bundle: .module) }
    static var openInNewWorkspace: String { String(localized: "handlers.findWork.openInNewWorkspace", defaultValue: "Open in New Workspace", table: "MiscHandlers", bundle: .module) }
    static var githubUnavailable: String { String(localized: "handlers.findWork.githubUnavailable", defaultValue: "GitHub work is unavailable", table: "MiscHandlers", bundle: .module) }
    static var githubUnavailableDetail: String { String(localized: "handlers.findWork.githubUnavailableDetail", defaultValue: "Install the GitHub CLI and run gh auth login.", table: "MiscHandlers", bundle: .module) }
    /// The bundle of this module's catalogs, so a test can read one language's table (`fr.lproj`).
    static var bundle: Bundle { .module }

    /// "3 unread": the accessory of a workspace that needs attention. The key is a plural
    /// variation, so the lookup picks the form for `count` ("1 non lu", "2 non lus"). `bundle` and
    /// `locale` default to this module's catalog in the user's language; a test passes one
    /// language's table and its locale.
    static func unread(_ count: Int, bundle: Bundle = .module, locale: Locale = .current) -> String {
        String(localized: "handlers.findWork.unread", defaultValue: "\(count) unread", table: "MiscHandlers",
               bundle: bundle, locale: locale)
    }
}
