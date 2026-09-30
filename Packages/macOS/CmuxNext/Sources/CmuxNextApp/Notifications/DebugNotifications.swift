import AppKit
import CmuxNextDesign
import CmuxNextSettings

/// `debug.notifications`: unread tabs with their source, the attention marks
/// each window draws, banners asked for, the arrival and dismissal log, and
/// the live preferences. `{"action": "click", "surface": <handle>}` runs the
/// banner click path (`DesktopNotifier.open`), for windows no one can click.
enum DebugNotifications {
    @MainActor
    static func handle(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let center = services.notifications
        if params["action"]?.stringValue == "click" {
            let surface = params["surface"]?.doubleValue.map { UInt64($0) }
            center.desktop.open(id: params["id"]?.stringValue ?? "debug", surface: surface)
        }
        let store = services.daemon.store
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
                "focused_tab": NotificationCenterService.contentTab(controller.focus.state.resolved).map(JSONValue.string) ?? .null,
            ]
        }
        let prefs = center.preferences
        let attention = DesignSettings.shared.attention
        return [
            "unread": .array(unread),
            "windows": .array(windows),
            "banners": .array(center.desktop.posted.map { banner in
                ["id": .string(banner.id), "title": .string(banner.title), "body": .string(banner.body),
                 "surface": banner.surface.map { .number(Double($0)) } ?? .null]
            }),
            "authorization": .string(center.desktop.authorization),
            "log": .array(center.log.map(JSONValue.string)),
            "dock_badge": center.dockBadgeLabel.map(JSONValue.string) ?? .null,
            "preferences": [
                "dismissal": .string(prefs.dismissal.rawValue), "desktop": .string(prefs.desktop.rawValue),
                "sound": .string(prefs.sound), "muted_workspaces": .array(prefs.mutedWorkspaces.sorted().map(JSONValue.string)),
                "attention_style": .string(attention.style.rawValue), "attention_width": .number(Double(attention.width)),
                "shows_on_tab": .bool(attention.showsOnTab), "shows_on_sidebar": .bool(attention.showsOnSidebar),
            ],
        ]
    }
}
