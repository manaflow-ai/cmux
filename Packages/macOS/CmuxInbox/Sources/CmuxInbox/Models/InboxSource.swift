import Foundation

/// The originating service for a normalized inbox item.
public enum InboxSource: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    /// Existing cmux agent feed and workstream events.
    case agent
    /// Gmail mailbox messages.
    case gmail
    /// Slack workspace conversations.
    case slack
    /// Discord bot-accessible guild channels, DMs, and threads.
    case discord
    /// iMessage helper events provided by `cmux-imsg`.
    case imessage
    /// macOS Notification Center records from every app, via `cmux-notif`.
    case notifications
    /// Generic CLI, webhook, Shortcuts, Zapier, or internal-tool events.
    case generic

    /// Stable identity used by SwiftUI lists and serialized payloads.
    public var id: String { rawValue }
}
