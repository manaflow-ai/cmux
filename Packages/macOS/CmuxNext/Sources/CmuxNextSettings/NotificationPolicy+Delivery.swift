/// Why an arrival's banner was or was not shown: the reasons the daemon's
/// `record-notification-delivery` takes (raw values are its wire strings), so
/// `list-notifications` can tell the agent and the banner probe "suppressed"
/// apart from "broken".
public nonisolated enum NotificationDeliveryReason: String, Hashable, Sendable, CaseIterable {
    case viewed
    case typing
    case muted
    case quietHours = "quiet-hours"
    case desktopNever = "desktop-never"
    case appActive = "app-active"
    case posterNoBanner = "poster-no-banner"
    case permissionDenied = "permission-denied"
    case incognito
    case digest
}

extension NotificationPolicy {
    /// The reason `decide(arrival)` posted no banner, nil when it posts one. It reads the
    /// same rules in the same order as ``decide(_:)``, so every suppressed decision maps
    /// to exactly one reason; ``decide(_:)`` itself is unchanged.
    public func suppression(of arrival: Arrival, decision: Decision) -> NotificationDeliveryReason? {
        if decision.desktop { return nil }
        if prefs.suppressWhileTypingSeconds > 0, let typed = arrival.typedAgo, typed <= prefs.suppressWhileTypingSeconds {
            return .typing
        }
        if prefs.dismissal(for: arrival.source) == .focus && arrival.paneIsViewed { return .viewed }
        if arrival.workspaceMuted { return .muted }
        if prefs.quietHours?.contains(minuteOfDay: arrival.minuteOfDay) ?? false { return .quietHours }
        if !prefs.postsDesktop(for: arrival.source) { return .desktopNever }
        if !decision.alerts {
            switch prefs.desktop {
            case .never: return .desktopNever
            case .unlessFocused: return .viewed
            case .whenInactive: return .appActive
            case .always: return .desktopNever
            }
        }
        return .posterNoBanner
    }
}

/// The `desktop` and `reason` fields `record-notification-delivery` gets for one arrival's outcome.
public nonisolated struct NotificationDeliveryReceipt: Hashable, Sendable {
    /// `shown` or `suppressed`.
    public let desktop: String
    public let reason: NotificationDeliveryReason?

    /// `suppressed` nil means a banner posted; `digest` and `incognito` say how. A banner
    /// posted while the system refuses banners is `permission-denied`.
    public init(suppressed: NotificationDeliveryReason?, digest: Bool = false, incognito: Bool = false, permissionDenied: Bool = false) {
        if let suppressed {
            desktop = "suppressed"
            reason = suppressed
        } else if permissionDenied {
            desktop = "suppressed"
            reason = .permissionDenied
        } else {
            desktop = "shown"
            reason = digest ? .digest : incognito ? .incognito : nil
        }
    }
}
