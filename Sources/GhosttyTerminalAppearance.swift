import AppKit
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
final class GhosttyDefaultBackgroundNotificationDispatcher {
    private let coalescer: NotificationBurstCoalescer
    private let postNotification: ([AnyHashable: Any]) -> Void
    private var pendingUserInfo: [AnyHashable: Any]?
    private var pendingEventId: UInt64 = 0
    private var pendingSource: String = "unspecified"
    private let logEvent: ((String) -> Void)?

    init(
        delay: TimeInterval = 1.0 / 30.0,
        logEvent: ((String) -> Void)? = nil,
        postNotification: @escaping ([AnyHashable: Any]) -> Void = { userInfo in
            NotificationCenter.default.post(
                name: .ghosttyDefaultBackgroundDidChange,
                object: nil,
                userInfo: userInfo
            )
        }
    ) {
        coalescer = NotificationBurstCoalescer(delay: delay)
        self.logEvent = logEvent
        self.postNotification = postNotification
    }

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
        let signalOnMain = { [self] in
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

        if Thread.isMainThread {
            signalOnMain()
        } else {
            DispatchQueue.main.async(execute: signalOnMain)
        }
    }
}

/// Coalesces terminal title notifications at the producer so tmux/title bursts
/// don't fan out through every NotificationCenter observer per escape sequence.
final class GhosttyTitleNotificationDispatcher {
    static let shared = GhosttyTitleNotificationDispatcher()

    private struct SurfaceKey: Hashable {
        let tabId: UUID
        let surfaceId: UUID
    }

    private struct PendingTitle {
        let object: Any?
        let title: String
    }

    private let coalescer: NotificationBurstCoalescer
    private let postNotification: (Any?, [AnyHashable: Any]) -> Void
    private var pendingTitles: [SurfaceKey: PendingTitle] = [:]
    private var lastPostedTitleBySurface: [SurfaceKey: String] = [:]

    init(
        delay: TimeInterval = 1.0 / 60.0,
        postNotification: @escaping (Any?, [AnyHashable: Any]) -> Void = { object, userInfo in
            NotificationCenter.default.post(
                name: .ghosttyDidSetTitle,
                object: object,
                userInfo: userInfo
            )
        }
    ) {
        coalescer = NotificationBurstCoalescer(delay: delay)
        self.postNotification = postNotification
    }

    func signal(object: Any?, tabId: UUID, surfaceId: UUID, title: String) {
        let signalOnMain = { [self] in
            let key = SurfaceKey(tabId: tabId, surfaceId: surfaceId)
            pendingTitles[key] = PendingTitle(object: object, title: title)
            coalescer.signal { [self] in
                flushPendingTitles()
            }
        }

        if Thread.isMainThread {
            signalOnMain()
        } else {
            DispatchQueue.main.async(execute: signalOnMain)
        }
    }

    private func flushPendingTitles() {
        guard !pendingTitles.isEmpty else { return }
        let titles = pendingTitles
        pendingTitles.removeAll(keepingCapacity: true)

        for (key, pendingTitle) in titles {
            guard lastPostedTitleBySurface[key] != pendingTitle.title else { continue }
            lastPostedTitleBySurface[key] = pendingTitle.title
            postNotification(
                pendingTitle.object,
                [
                    GhosttyNotificationKey.tabId: key.tabId,
                    GhosttyNotificationKey.surfaceId: key.surfaceId,
                    GhosttyNotificationKey.title: pendingTitle.title,
                ]
            )
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
