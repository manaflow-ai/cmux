import Foundation

// The Publish popover (BrowserPublishPopover), under the toolbar's Publish button.
nonisolated extension Strings {
    static var publishTitle: String {
        String(localized: "browser.publish.title", defaultValue: "Publish App", bundle: .localizedModule)
    }
    static var publishNamePlaceholder: String {
        String(localized: "browser.publish.namePlaceholder", defaultValue: "App name", bundle: .localizedModule)
    }
    static var publishPrivate: String {
        String(localized: "browser.publish.private", defaultValue: "Private", bundle: .localizedModule)
    }
    static var publishTeam: String {
        String(localized: "browser.publish.team", defaultValue: "Team", bundle: .localizedModule)
    }
    static var publishStartFrom: String {
        String(localized: "browser.publish.startFrom", defaultValue: "Start from", bundle: .localizedModule)
    }
    static var publishOpen: String {
        String(localized: "browser.publish.open", defaultValue: "Open", bundle: .localizedModule)
    }
    static var publishUnavailable: String {
        String(localized: "browser.publish.unavailable", defaultValue: "This page can’t be published.", bundle: .localizedModule)
    }
    static var publishNameEmpty: String {
        String(localized: "browser.publish.nameEmpty", defaultValue: "The name needs a letter or a digit.", bundle: .localizedModule)
    }
    static func publishPublished(_ url: String) -> String {
        String(localized: "browser.publish.published", defaultValue: "Published at \(url)", bundle: .localizedModule)
    }
    /// A publish went live but its run named no address: `name` is the app's.
    static func publishPublishedNamed(_ name: String) -> String {
        String(localized: "browser.publish.publishedNamed", defaultValue: "Published \(name)", bundle: .localizedModule)
    }
    static func publishFailed(code: String, message: String) -> String {
        String(localized: "browser.publish.failed", defaultValue: "Publish failed (\(code)): \(message)", bundle: .localizedModule)
    }
    static func publishUnreadable(_ exit: Int) -> String {
        String(localized: "browser.publish.unreadable", defaultValue: "Publish ended with exit code \(exit), but its answer could not be read.", bundle: .localizedModule)
    }
    static func publishUnreachable(_ reason: String) -> String {
        String(localized: "browser.publish.unreachable", defaultValue: "Could not reach the machine: \(reason)", bundle: .localizedModule)
    }
}
