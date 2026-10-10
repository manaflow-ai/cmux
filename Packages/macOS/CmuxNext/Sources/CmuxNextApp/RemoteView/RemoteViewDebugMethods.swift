import CmuxNextControl
import CmuxNextSettings
import CmuxNextRemoteView
import Foundation

/// `debug.remote_view` (development builds): the live `remote_view` tabs and
/// their sessions, for live checks of the desktop pane (cx-wb5.75).
/// - `state` (default): one row per tab: its URL, whether it asks first
///   (`confirm`), and its session (`RemoteViewPageSession.debugState`).
/// - `open` {url, pane?}: opens `url` (a `cmux://remote-view` record) in a
///   new tab of `pane`, else the active window's focused pane, else the
///   first window's. An unconfirmed record asks first, as any automation.
/// - `connect` {tab?}: presses Connect on the tabs that ask first (the same
///   closure as the button: a confirmed tab starts in view mode).
extension AppControl {
    func registerRemoteViewDebugMethods(_ services: AppServices) {
        #if DEBUG
        service?.router.register([
            .async("debug.remote_view") { [weak services] call in
                guard let services else { return .null }
                return await remoteViewDebug(call.params, services: services)
            },
        ])
        #endif
    }
}

#if DEBUG
@MainActor
private func remoteViewDebug(_ params: [String: JSONValue], services: AppServices) async -> JSONValue {
    let only = params["tab"]?.stringValue
    let tabs = RemoteViewPageTab.live.allObjects.filter { only == nil || $0.id.rawValue == only }
    switch params["action"]?.stringValue ?? "state" {
    case "open":
        guard let url = params["url"]?.stringValue.flatMap(URL.init(string:)), RemoteViewTabRecord.matches(url) else {
            return ["error": "url must be a cmux://remote-view record"]
        }
        let named = params["pane"]?.stringValue.flatMap { key in
            services.windows.controllers.lazy.compactMap { $0.content?.panes.values.first { $0.paneKey == key } }.first
        }
        guard let pane = named ?? services.windows.active?.focusedPane ?? services.windows.controllers.first?.focusedPane else {
            return ["error": "no pane"]
        }
        pane.newBrowserTab(url: url)
        return ["opened": true]
    case "connect":
        let connects = tabs.compactMap(\.debugConnect)
        for connect in connects { connect() }
        return ["pressed": .number(Double(connects.count))]
    case "state":
        var rows: [JSONValue] = []
        for tab in tabs {
            let session: JSONValue = if let live = tab.debugSession { await live.debugState() } else { .null }
            rows.append(.object([
                "tab": .string(tab.id.rawValue), "url": tab.state.url.map { .string($0.absoluteString) } ?? .null,
                "confirm": .bool(tab.debugConnect != nil), "session": session,
            ]))
        }
        return ["tabs": .array(rows)]
    default:
        return ["error": "unknown action"]
    }
}
#endif
