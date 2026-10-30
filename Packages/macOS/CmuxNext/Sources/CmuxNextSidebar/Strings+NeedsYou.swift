import Foundation

extension Strings {
    /// The session tree's needs-you tray: its header.
    static var needsYou: String { String(localized: "sidebar.needsYou.title", defaultValue: "Needs You", bundle: .module) }

    /// Why a tray item waits on you: what the agent asks for, else that it waits, or that it failed.
    static func needsYouReason(_ item: SidebarNeedsYouItem) -> String {
        guard item.reason == .waiting else {
            return String(localized: "sidebar.needsYou.failed", defaultValue: "Failed", bundle: .module)
        }
        return switch item.kind {
        case .question?: String(localized: "sidebar.needsYou.question", defaultValue: "Question", bundle: .module)
        case .permission?: String(localized: "sidebar.needsYou.permission", defaultValue: "Approve", bundle: .module)
        case .auth?: String(localized: "sidebar.needsYou.auth", defaultValue: "Sign In", bundle: .module)
        case nil: String(localized: "sidebar.needsYou.waiting", defaultValue: "Waiting", bundle: .module)
        }
    }

    /// The tray's last line: the blocked sessions it has no room for.
    static func needsYouMore(_ count: Int) -> String {
        String(localized: "sidebar.needsYou.more", defaultValue: "\(count) more", bundle: .module)
    }

    /// The tray's last line: finished sessions with output you have not read.
    static func needsYouUnread(_ count: Int) -> String {
        String(localized: "sidebar.needsYou.unread", defaultValue: "\(count) finished, unread", bundle: .module)
    }

    /// The tray, for VoiceOver.
    static func needsYouSummary(blocked: Int, unread: Int) -> String {
        String(localized: "sidebar.a11y.needsYou", defaultValue: "Needs you: \(blocked) waiting, \(unread) finished and unread", bundle: .module)
    }
}
