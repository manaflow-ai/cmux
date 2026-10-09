import Foundation

/// The Notification Service extension's decision for one feed push (pure):
/// category assignment, this device's preferences, expiry and preview
/// shortening (c7-notify.md section 5). Without the filtering entitlement a
/// push cannot be dropped, so "off" and "expired" become passive and silent.
public struct PushPresentation: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case shown
        /// The device turned this kind off.
        case silenced
        /// The item stopped mattering before delivery.
        case expired
    }

    public static let titleLimit = 80
    public static let subtitleLimit = 80
    public static let bodyLimit = 178

    public var content: PushContent
    public var outcome: Outcome
    public var kind: NotificationKind?

    /// `expiredBody` is the localized replacement body for an expired item.
    public init(content original: PushContent, userInfo: [AnyHashable: Any], preferences: NotificationPreferences?,
                now: Date, expiredBody: String) {
        var content = original
        let payload = FeedPushPayload(userInfo: userInfo)
        if let payload, FeedPushCategory(rawValue: content.category) == nil, let category = payload.resolvedCategory {
            content.category = category.rawValue
        }
        // The owner names the kind; the table is the fallback for older owners.
        let kind = payload?.notifyKind ?? NotificationKind(feedKind: payload?.kind, type: payload?.type, category: content.category)
        self.kind = kind
        content.title = Self.shortened(content.title, to: Self.titleLimit)
        content.subtitle = Self.shortened(content.subtitle, to: Self.subtitleLimit)
        content.body = Self.shortened(content.body, to: Self.bodyLimit)
        if let preferences {
            if !preferences.sound { content.sound = false }
            if content.level == .timeSensitive, !(preferences.timeSensitive && kind?.isRequest == true) {
                content.level = .active
            }
        }
        if let expiresAt = payload?.expiresAt, expiresAt <= now {
            content.body = expiredBody
            content.level = .passive
            content.sound = false
            outcome = .expired
        } else if let kind, let preferences, !preferences.isEnabled(kind) {
            content.level = .passive
            content.sound = false
            outcome = .silenced
        } else {
            outcome = .shown
        }
        self.content = content
    }

    /// Cuts `text` to at most `limit` characters on a character boundary,
    /// ending with an ellipsis when it was cut. Whitespace runs collapse so
    /// the lock screen shows words, not blank lines.
    public static func shortened(_ text: String, to limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        var cut = String(collapsed.prefix(limit - 1))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = String(cut[..<space])
        }
        return cut + "…"
    }
}
