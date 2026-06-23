import Foundation

struct NotificationMuteMenuOption: Hashable, Identifiable {
    enum Kind: Hashable {
        case untilUnmuted
        case duration(TimeInterval)
    }

    let id: String
    let title: String
    let kind: Kind

    static var untilUnmuted: NotificationMuteMenuOption {
        NotificationMuteMenuOption(
            id: "until-unmuted",
            title: String(localized: "notificationMute.duration.untilUnmuted", defaultValue: "Until Unmuted"),
            kind: .untilUnmuted
        )
    }

    static var defaultTimedOptions: [NotificationMuteMenuOption] {
        [
            .timed(
                id: "15m",
                title: String(localized: "notificationMute.duration.fifteenMinutes", defaultValue: "15 Minutes"),
                interval: 15 * 60
            ),
            .timed(
                id: "1h",
                title: String(localized: "notificationMute.duration.oneHour", defaultValue: "1 Hour"),
                interval: 60 * 60
            ),
            .timed(
                id: "4h",
                title: String(localized: "notificationMute.duration.fourHours", defaultValue: "4 Hours"),
                interval: 4 * 60 * 60
            ),
            .timed(
                id: "8h",
                title: String(localized: "notificationMute.duration.eightHours", defaultValue: "8 Hours"),
                interval: 8 * 60 * 60
            ),
        ]
    }

    static var defaultOptions: [NotificationMuteMenuOption] {
        [untilUnmuted] + defaultTimedOptions
    }

    static func options(configuredDurations: [CmuxNotificationMuteDurationDefinition]?) -> [NotificationMuteMenuOption] {
        guard let configuredDurations else {
            return defaultOptions
        }
        let timedOptions = configuredDurations.enumerated().map { index, definition in
            NotificationMuteMenuOption.timed(
                id: "configured-\(index)-\(definition.label)-\(definition.interval)",
                title: definition.label,
                interval: definition.interval
            )
        }
        return [untilUnmuted] + timedOptions
    }

    static func timed(id: String, title: String, interval: TimeInterval) -> NotificationMuteMenuOption {
        NotificationMuteMenuOption(id: id, title: title, kind: .duration(interval))
    }

    func expiration(from date: Date = Date()) -> Date {
        switch kind {
        case .untilUnmuted:
            return .distantFuture
        case .duration(let interval):
            return date.addingTimeInterval(interval)
        }
    }
}
