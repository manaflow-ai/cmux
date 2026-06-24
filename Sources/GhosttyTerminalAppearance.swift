import AppKit
import CmuxFoundation
import Foundation

enum GhosttyDefaultBackgroundUpdateScope: Int {
    case unscoped = 0
    case app = 1
    case surface = 2

    var logLabel: String {
        switch self {
        case .unscoped: return "unscoped"
        case .app: return "app"
        case .surface: return "surface"
        }
    }
}

/// Coalesces Ghostty appearance notifications so consumers only observe the
/// latest runtime terminal colors for a burst of updates.
@MainActor
final class GhosttyDefaultBackgroundNotificationDispatcher {
    private let coalescer: NotificationBurstCoalescer
    private let postNotification: @MainActor ([AnyHashable: Any]) -> Void
    private var pendingUserInfo: [AnyHashable: Any]?
    private var pendingEventId: UInt64 = 0
    private var pendingSource: String = "unspecified"
    private let logEvent: (@MainActor (String) -> Void)?

    init(
        delay: TimeInterval = 1.0 / 30.0,
        coalescer: NotificationBurstCoalescer? = nil,
        logEvent: (@MainActor (String) -> Void)? = nil,
        postNotification: @escaping @MainActor ([AnyHashable: Any]) -> Void = { userInfo in
            NotificationCenter.default.post(
                name: .ghosttyDefaultBackgroundDidChange,
                object: nil,
                userInfo: userInfo
            )
        }
    ) {
        self.coalescer = coalescer ?? NotificationBurstCoalescer(delay: delay)
        self.logEvent = logEvent
        self.postNotification = postNotification
    }

    @MainActor
    func signal(
        backgroundColor: NSColor,
        opacity: Double,
        eventId: UInt64,
        source: String,
        foregroundColor: NSColor,
        cursorColor: NSColor,
        cursorTextColor: NSColor,
        selectionBackground: NSColor,
        selectionForeground: NSColor
    ) {
        pendingEventId = eventId
        pendingSource = source
        pendingUserInfo = [
            GhosttyNotificationKey.backgroundColor: backgroundColor,
            GhosttyNotificationKey.backgroundOpacity: opacity,
            GhosttyNotificationKey.backgroundEventId: NSNumber(value: eventId),
            GhosttyNotificationKey.backgroundSource: source,
            GhosttyNotificationKey.foregroundColor: foregroundColor,
            GhosttyNotificationKey.cursorColor: cursorColor,
            GhosttyNotificationKey.cursorTextColor: cursorTextColor,
            GhosttyNotificationKey.selectionBackground: selectionBackground,
            GhosttyNotificationKey.selectionForeground: selectionForeground,
        ]
        logEvent?(
            "bg notify queued id=\(eventId) source=\(source) color=\(backgroundColor.hexString()) fg=\(foregroundColor.hexString()) opacity=\(String(format: "%.3f", opacity))"
        )
        coalescer.signal { [self] in
            guard let userInfo = pendingUserInfo else { return }
            let eventId = pendingEventId
            let source = pendingSource
            pendingUserInfo = nil
            logEvent?("bg notify flushed id=\(eventId) source=\(source)")
            logEvent?("bg notify posting id=\(eventId) source=\(source)")
            postNotification(userInfo)
            logEvent?("bg notify posted id=\(eventId) source=\(source)")
        }
    }
}

enum GhosttyNotificationKey {
    static let scrollbar = "ghostty.scrollbar"
    static let cellSize = "ghostty.cellSize"
    static let tabId = "ghostty.tabId"
    static let surfaceId = "ghostty.surfaceId"
    static let explicitFocusIntent = "ghostty.explicitFocusIntent"
    static let title = "ghostty.title"
    static let backgroundColor = "ghostty.backgroundColor"
    static let backgroundOpacity = "ghostty.backgroundOpacity"
    static let backgroundEventId = "ghostty.backgroundEventId"
    static let backgroundSource = "ghostty.backgroundSource"
    static let foregroundColor = "ghostty.foregroundColor"
    static let cursorColor = "ghostty.cursorColor"
    static let cursorTextColor = "ghostty.cursorTextColor"
    static let selectionBackground = "ghostty.selectionBackground"
    static let selectionForeground = "ghostty.selectionForeground"
}
