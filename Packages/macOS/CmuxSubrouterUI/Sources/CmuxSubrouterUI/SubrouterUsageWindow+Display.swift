internal import Foundation
public import CmuxSubrouter

extension SubrouterUsageWindow {
    /// A localized short label for the window, mirroring the `sr` CLI's
    /// `windowLabel`: length-based names for Codex (`5h limit`, `7d limit`),
    /// feature prefixes preserved, and raw daemon names otherwise.
    public var displayLabel: String {
        let lowered = name.lowercased()
        if lowered == "primary" || lowered.hasSuffix("/primary") {
            let prefix = featurePrefix
            let span = shortSpanText
            if let prefix {
                return String(
                    localized: "subrouter.window.featureShortLimit",
                    defaultValue: "\(prefix) (\(span))"
                )
            }
            return span
        }
        if lowered == "secondary" || lowered.hasSuffix("/secondary") {
            let prefix = featurePrefix
            let span = longSpanText
            if let prefix {
                return String(
                    localized: "subrouter.window.featureLongLimit",
                    defaultValue: "\(prefix) (\(span))"
                )
            }
            return span
        }
        switch lowered {
        case "5h":
            return String(localized: "subrouter.window.session", defaultValue: "Session (5h)")
        case "7d":
            return String(localized: "subrouter.window.weekly", defaultValue: "Weekly (7d)")
        case "opus-weekly":
            return String(localized: "subrouter.window.opusWeekly", defaultValue: "Opus weekly")
        case "sonnet-weekly":
            return String(localized: "subrouter.window.sonnetWeekly", defaultValue: "Sonnet weekly")
        case "extra":
            return String(localized: "subrouter.window.extra", defaultValue: "Extra")
        default:
            return name
        }
    }

    /// The feature name for `<Feature>/primary`-style windows, else `nil`.
    private var featurePrefix: String? {
        if !feature.isEmpty { return feature }
        guard let slash = name.firstIndex(of: "/") else { return nil }
        let prefix = String(name[..<slash])
        return prefix.isEmpty ? nil : prefix
    }

    private var shortSpanText: String {
        // Multi-day "short" windows (some daemons report a 168h primary)
        // read better as days than as a three-digit hour count.
        if limitWindowSeconds >= 48 * 3600 {
            let days = max(1, Int((Double(limitWindowSeconds) / 86_400).rounded()))
            return String(localized: "subrouter.window.dayLimit", defaultValue: "\(days)d limit")
        }
        let hours = max(1, Int((Double(limitWindowSeconds) / 3600).rounded()))
        return String(localized: "subrouter.window.hourLimit", defaultValue: "\(hours)h limit")
    }

    private var longSpanText: String {
        guard limitWindowSeconds >= 86_400 else {
            return String(localized: "subrouter.window.weeklyLimit", defaultValue: "Weekly limit")
        }
        let days = max(1, Int((Double(limitWindowSeconds) / 86_400).rounded()))
        return String(localized: "subrouter.window.dayLimit", defaultValue: "\(days)d limit")
    }

    /// A localized countdown like “resets in 2d 4h”, or `nil` when the daemon
    /// reported no reset time.
    public var resetCountdownText: String? {
        guard resetAfterSeconds > 0 else { return nil }
        let spanText = Self.durationText(seconds: resetAfterSeconds)
        return String(localized: "subrouter.window.resetsIn", defaultValue: "resets in \(spanText)")
    }

    /// The bare countdown duration (`2d 4h`) for tight trailing slots, or
    /// `nil` when the daemon reported no reset time.
    public var shortResetText: String? {
        guard resetAfterSeconds > 0 else { return nil }
        return Self.durationText(seconds: resetAfterSeconds)
    }

    /// Formats a duration the way `sr` does: `2d 4h`, `3h 12m`, `<1m`.
    static func durationText(seconds: Int64) -> String {
        guard seconds > 0 else {
            return String(localized: "subrouter.duration.now", defaultValue: "now")
        }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        var parts: [String] = []
        if days > 0 {
            parts.append(String(localized: "subrouter.duration.days", defaultValue: "\(days)d"))
        }
        if hours > 0 {
            parts.append(String(localized: "subrouter.duration.hours", defaultValue: "\(hours)h"))
        }
        if minutes > 0 && days == 0 {
            parts.append(String(localized: "subrouter.duration.minutes", defaultValue: "\(minutes)m"))
        }
        if parts.isEmpty {
            return String(localized: "subrouter.duration.underMinute", defaultValue: "<1m")
        }
        return parts.joined(separator: " ")
    }
}
