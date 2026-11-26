package import AppKit
package import CmuxNextDaemon
package import CmuxNextSettings
import CmuxNextWindowRules

/// What VoiceOver says when an agent in another chat needs the person, fails or finishes while cmux
/// is in front and no banner shows for it: `notifications.desktop` is `whenInactive` or `never`, the
/// poster asked for none (`notify --desktop false`), or macOS denies cmux banners. The sidebar row
/// changes then and nothing is said. WCAG 2.2 SC 4.1.3 Status Messages: a status change is announced
/// without moving focus. A banner that shows is not said again (VoiceOver reads the banner), and nothing
/// is said for a pane in view, a muted workspace, quiet hours or Quiet After Typing; the policy's
/// decision already carries those.
package struct AgentStatusAnnouncement {
    package init() {}
    package nonisolated enum Kind: String, Equatable, Sendable, Decodable {
        case needsYou, failed, finished
    }

    /// The kind of an agent notification by its level, nil for any other poster's (cmux-window-rules
    /// `desktop_announce`; nil when the rule does not answer).
    package static func kind(level: NotificationLevel, source: String?) -> Kind? {
        struct Request: Encodable {
            var level: String
            var source: String?
        }
        struct Reply: Decodable {
            var kind: Kind?
        }
        return WindowRules().call("window_notifications_desktop_announce_kind", Request(level: level.rawValue, source: source),
                                  as: Reply.self)?.kind
    }

    /// Whether an arrival the policy decided is said: it rings (not muted, not read on sight), no
    /// banner shows for it, cmux is in front, and its pane is not. `bannersDenied`: macOS refuses cmux
    /// banners (``DesktopNotifier/authorization`` is "denied"), so a decided banner never shows.
    /// Nothing is said when the rule does not answer.
    package static func speaks(_ decision: NotificationPolicy.Decision, bannersDenied: Bool, appActive: Bool,
                               paneIsViewed: Bool) -> Bool {
        struct Request: Encodable {
            var attention: Bool
            var acknowledge: Bool
            var desktop: Bool
            var bannersDenied: Bool
            var appActive: Bool
            var paneIsViewed: Bool
        }
        struct Reply: Decodable {
            var speaks: Bool
        }
        let request = Request(attention: decision.attention, acknowledge: decision.acknowledge, desktop: decision.desktop,
                              bannersDenied: bannersDenied, appActive: appActive, paneIsViewed: paneIsViewed)
        return WindowRules().call("window_notifications_desktop_announce_speaks", request, as: Reply.self)?.speaks ?? false
    }

    /// The line: "build-fix: Needs you", or the kind alone when the chat's name is not said (an
    /// incognito window's chat).
    package static func text(_ kind: Kind, name: String?) -> String {
        let word = switch kind {
        case .needsYou: String(localized: "notifications.attention.needsYou", defaultValue: "Needs you", bundle: .localizedModule)
        case .failed: String(localized: "notifications.announce.failed", defaultValue: "Failed", bundle: .localizedModule)
        case .finished: String(localized: "notifications.announce.finished", defaultValue: "Finished", bundle: .localizedModule)
        }
        guard let name, !name.isEmpty else { return word }
        return "\(name): \(word)"
    }

    /// A finished turn waits its turn behind what VoiceOver is saying; an ask or a failure says itself at once.
    package static func priority(_ kind: Kind) -> NSAccessibilityPriorityLevel {
        kind == .finished ? .medium : .high
    }

    /// Says `kind` for the chat named `name`. Focus stays where it is.
    @MainActor
    package static func announce(_ kind: Kind, name: String?) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text(kind, name: name), .priority: priority(kind).rawValue,
        ])
    }
}

extension DesktopNotifier {
    /// Says an agent arrival when ``AgentStatusAnnouncement/speaks(_:bannersDenied:appActive:paneIsViewed:)``
    /// does, with this notifier's banner permission; the kind it said, nil when it said nothing.
    /// `name`: the chat's name, nil to leave it out (an incognito window's chat).
    @discardableResult
    package func announce(_ notification: DaemonNotification, decision: NotificationPolicy.Decision, appActive: Bool,
                          paneIsViewed: Bool, name: @autoclosure () -> String?) -> AgentStatusAnnouncement.Kind? {
        guard let kind = AgentStatusAnnouncement.kind(level: notification.level, source: notification.source),
              AgentStatusAnnouncement.speaks(decision, bannersDenied: authorization == "denied", appActive: appActive,
                                             paneIsViewed: paneIsViewed) else { return nil }
        AgentStatusAnnouncement.announce(kind, name: name())
        return kind
    }
}

extension DaemonStore {
    /// The workspace a terminal-less notification names (`cmux notify --workspace ws_…`), when it is
    /// in this store.
    package func workspace(namedBy notification: DaemonNotification) -> WorkspaceModel? {
        guard notification.surface == nil, let id = notification.workspaceID else { return nil }
        return workspace(resourceID: id)
    }
}
