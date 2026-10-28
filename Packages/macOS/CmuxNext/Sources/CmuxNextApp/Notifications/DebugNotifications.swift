import AppKit
import CmuxNextDesign
import CmuxNextSettings

/// `debug.notifications`: unread tabs with their source, the attention marks
/// each window draws, banners asked for, the arrival and dismissal log, and
/// the live preferences. `{"action": "click", "surface": <handle>, "tab": <tab id>}` runs the
/// banner click path (`DesktopNotifier.received`), for windows no one can click;
/// `{"action": "reply", "surface": <handle>, "id": <banner id>, "text": <text>}` runs a reply
/// banner's Send (`DesktopNotifier.received`).
/// `{"action": "allow" | "deny", "surface": <handle>, "id": <banner id>}` runs an approval
/// banner's Allow once or Deny (`DesktopNotifier.received`).
/// `{"action": "mark_read", "surface": <handle>, "id": <banner id>}` runs a banner's Mark as Read
/// (`DesktopNotifier.received`).
/// `{"action": "dismiss_highlight", "workspace": <id>}` hides that
/// workspace's attention rings until a newer notification (cx-epgo).
enum DebugNotifications {
    @MainActor
    static func handle(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let center = services.notifications
        // `"tab": <tab id>` names the banner's tab as a banner does (`DesktopNotifier.Posted.tab`).
        let surface = params["surface"]?.doubleValue.map { UInt64($0) }
        let tab = params["tab"]?.stringValue
        let id = params["id"]?.stringValue ?? ""
        let action: DesktopNotifier.BannerResponse.Action? = switch params["action"]?.stringValue {
        case "click": .open
        case "reply": params["text"]?.stringValue.map { .reply($0) }
        case "allow": .approve(true)
        case "deny": .approve(false)
        case "mark_read": .markRead
        default: nil
        }
        if let action { center.desktop.received(DesktopNotifier.BannerResponse(id: id, surface: surface, tab: tab, action: action)) }
        let store = services.daemon.store
        // `{"action": "dismiss_highlight", "workspace": <id>}`: the Dismiss Highlight path (cx-epgo).
        if params["action"]?.stringValue == "dismiss_highlight", let id = params["workspace"]?.stringValue,
           let workspace = store.workspaces.first(where: { $0.id == id }) {
            center.dismissHighlight(workspace)
        }
        var unread: [JSONValue] = []
        for workspace in store.workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs where tab.hasUnread {
                        unread.append([
                            "workspace": .string(workspace.id), "pane": .string(pane.id), "tab": .string(tab.id),
                            "surface": .number(Double(tab.surface.rawValue)),
                            "notification": .number(Double(tab.notification?.notification.rawValue ?? 0)),
                            "source": .string(center.source(of: tab).rawValue),
                        ])
                    }
                }
            }
        }
        let windows: [JSONValue] = services.windows.controllers.map { controller in
            let marks = controller.content?.layoutModel.attention ?? [:]
            return [
                "id": .string(controller.state.id),
                "attention": .array(marks.keys.sorted().map { .string($0.rawValue) }),
                "focused_tab": NotificationCenterService.shownFocus(controller).flatMap(NotificationCenterService.contentTab).map(JSONValue.string) ?? .null,
            ]
        }
        let prefs = center.preferences
        let attention = DesignSettings.shared.attention
        return [
            "unread": .array(unread),
            "windows": .array(windows),
            "banners": .array(center.desktop.posted.map(banner)),
            "authorization": .string(center.desktop.authorization),
            "log": .array(center.log.map(JSONValue.string)),
            "feed_log": .array((center.feedDriver?.log ?? []).map(JSONValue.string)),
            "dock_badge": center.dockBadgeLabel.map(JSONValue.string) ?? .null,
            "dismissed_highlights": .object(center.dismissedHighlights.mapValues { .number(Double($0)) }),
            "highlight_look": .string(AttentionHighlightLook.tunable.value.rawValue),
            "preferences": [
                "dismissal": .string(prefs.dismissal.rawValue), "desktop": .string(prefs.desktop.rawValue),
                "sound": .string(prefs.sound), "muted_workspaces": .array(prefs.mutedWorkspaces.sorted().map(JSONValue.string)),
                "attention_style": .string(attention.style.rawValue), "attention_width": .number(Double(attention.width)),
                "shows_on_tab": .bool(attention.showsOnTab), "shows_on_sidebar": .bool(attention.showsOnSidebar),
            ],
        ]
    }

    /// One banner the app asked for, with its status badge (`attachment`:
    /// byte count and the PNG as base64, null when the banner had none).
    static func banner(_ banner: DesktopNotifier.Posted) -> JSONValue {
        [
            "id": .string(banner.id), "title": .string(banner.title),
            "subtitle": banner.subtitle.map(JSONValue.string) ?? .null, "body": .string(banner.body),
            "surface": banner.surface.map { .number(Double($0)) } ?? .null,
            "reply": .bool(banner.reply), "approval": .bool(banner.approval),
            "category": banner.category.map(JSONValue.string) ?? .null,
            "attachment": banner.attachment.map { data in
                ["bytes": .number(Double(data.count)), "png_base64": .string(data.base64EncodedString())]
            } ?? .null,
        ]
    }
}
