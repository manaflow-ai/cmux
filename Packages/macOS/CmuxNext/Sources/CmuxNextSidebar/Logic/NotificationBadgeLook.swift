public import CmuxNextDesign
public import CmuxNextIcons
import Foundation

/// How the unread counter and the unread dot draw in every sidebar badge
/// (workspace rows, group headers, the Notifications item; cx-epgo, the Leo
/// call of 2026-10-09). Debug Settings `sidebar.notificationBadge` switches
/// it live (`debug.tunables set`); Lawrence picks one in dogfood. Every look
/// keeps the same badge size, so a switch never moves a row's text. Colors
/// come from the Ghostty theme: never a blue accent.
public nonisolated enum NotificationBadgeLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The count on a neutral fill, a bright dot (the look before cx-epgo).
    case classic
    /// The count as quiet secondary text, no fill; a dimmed dot.
    case quiet
    /// The count in a hairline capsule, no fill; a hollow ring for the dot.
    case outline
    /// The count on a faint wash of the theme's attention color (ANSI yellow), in that color.
    case tone

    public var tunableTitle: String {
        switch self {
        case .classic: "Classic (neutral fill)"
        case .quiet: "Quiet (text only)"
        case .outline: "Outline (hairline capsule)"
        case .tone: "Tone (attention wash)"
        }
    }

    public static let tunable = Tunable<NotificationBadgeLook>.choice(
        "sidebar.notificationBadge", .status, "Notification badge",
        help: "How the unread counter and dot draw in sidebar rows, group headers and the Notifications item (cx-epgo).",
        default: .classic, code: "NotificationBadgeLook.tunable")
}

/// The Notifications item's glyph (Debug Settings `sidebar.notificationIcon`,
/// cx-epgo): the registry bell, the registry inbox, or an SF Symbol.
public nonisolated enum NotificationIconLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The cmux icon registry bell (the look before cx-epgo).
    case bell
    /// The cmux icon registry inbox tray.
    case inbox
    /// The SF Symbol bell, thinner than the registry one.
    case symbolBell
    /// The SF Symbol tray.
    case symbolTray

    public var tunableTitle: String {
        switch self {
        case .bell: "Bell"
        case .inbox: "Inbox"
        case .symbolBell: "Bell (SF Symbol)"
        case .symbolTray: "Tray (SF Symbol)"
        }
    }

    /// The registry icon this look draws; nil draws `symbol`.
    public var icon: IconName? {
        switch self {
        case .bell: .notification
        case .inbox: .inbox
        case .symbolBell, .symbolTray: nil
        }
    }

    /// The SF Symbol drawn when `icon` is nil.
    public var symbol: String {
        switch self {
        case .bell, .symbolBell: "bell"
        case .inbox, .symbolTray: "tray"
        }
    }

    public static let tunable = Tunable<NotificationIconLook>.choice(
        "sidebar.notificationIcon", .status, "Notification icon",
        help: "The glyph of the sidebar's Notifications item (cx-epgo).",
        default: .bell, code: "NotificationIconLook.tunable")
}
