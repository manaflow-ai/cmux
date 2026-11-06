import Foundation

extension Strings {
    /// The arrival card's header (`SidebarNotificationEmphasis.arrivalCard`).
    static var attentionArrived: String { String(localized: "sidebar.attention.arrived", defaultValue: "Just In", bundle: .module) }

    /// Why a shelf line asks for you: its unread count, what it waits for, or that it failed.
    static func attentionReason(_ attention: WorkspaceRowAttention) -> String {
        switch attention.kind {
        case .unread:
            String(localized: "sidebar.attention.new", defaultValue: "\(attention.count) new", bundle: .module)
        case .failed:
            String(localized: "sidebar.needsYou.failed", defaultValue: "Failed", bundle: .module)
        case .needsYou:
            switch attention.blocked {
            case .question?: String(localized: "sidebar.needsYou.question", defaultValue: "Question", bundle: .module)
            case .permission?: String(localized: "sidebar.needsYou.permission", defaultValue: "Approve", bundle: .module)
            case .auth?: String(localized: "sidebar.needsYou.auth", defaultValue: "Sign In", bundle: .module)
            case nil: String(localized: "sidebar.needsYou.waiting", defaultValue: "Waiting", bundle: .module)
            }
        }
    }

    /// The loud-rows look's top beacon: rows with a notification scrolled out of view above.
    static func attentionAbove(_ count: Int) -> String {
        String(localized: "sidebar.attention.above", defaultValue: "↑ \(count) above", bundle: .module)
    }

    /// The loud-rows look's bottom beacon: rows with a notification scrolled out of view below.
    static func attentionBelow(_ count: Int) -> String {
        String(localized: "sidebar.attention.below", defaultValue: "↓ \(count) below", bundle: .module)
    }
}
