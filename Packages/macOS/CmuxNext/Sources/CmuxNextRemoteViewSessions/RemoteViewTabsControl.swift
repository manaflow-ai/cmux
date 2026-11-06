public import CmuxNextSettings
public import CmuxNextRemoteView
import Foundation

/// The control socket's view of the live `remote_view` tabs (`remote_view.state` and
/// `remote_view.mode` in every build, `debug.remote_view` in development builds), for automation
/// such as the production desktop probe. `cloudOnly` (the release methods) answers about and acts
/// on Cloud desktop tabs only, the one kind a release build shows.
/// - `state`: one row per tab: `tab`, `url`, whether it asks first (`confirm`), its `viewer`
///   (`rd`, `vnc` or `mock`), whether it is `connected` (streaming), who has `control` (`person`
///   after Take over, else `agent`: the machine's own agent drives its display), and its session
///   (`RemoteViewPageSession.debugState`: `decoded`, `mode`, `state`, ...). No credential and no
///   pixel of the screen. `cmux app remote-views [--tab TAB]` reads it in every build.
/// - `connect` {tab?} (development only): presses Connect on the tabs that ask first (the
///   button's own closure; a confirmed tab starts watching).
/// - `mode` {tab, mode: control|view}: Take over or Hand back on that tab's session. Release
///   (`cloudOnly`) takes only `view` (Hand back).
///
/// Why release refuses `connect` and `mode control`: Connect stands in for the person's click, and
/// control of someone's desktop is never an agent's to take. Control input comes only from the
/// person's own pane (its Take over button); automation may watch and may hand control back.
@MainActor
public struct RemoteViewTabsControl {
    public init() {}
    /// The methods every build registers (RemoteViewDebugMethods). The CLI's `app remote-views`
    /// reads the first (`REMOTE_VIEWS_METHOD` in cmux-tui's cli/app.rs; a test holds the two equal).
    nonisolated public static let releaseMethods = ["remote_view.state", "remote_view.mode"]
    public static func answer(_ params: [String: JSONValue], cloudOnly: Bool) async -> JSONValue {
        let only = params["tab"]?.stringValue
        let tabs = RemoteViewPageTab.live.allObjects.filter { tab in
            (only == nil || tab.id.rawValue == only) && (!cloudOnly || tab.record?.cloudDesktop == true)
        }
        switch params["action"]?.stringValue ?? "state" {
        case "connect":
            if cloudOnly { return ["error": "connect is the person's click; not on the control socket"] }
            let connects = tabs.compactMap(\.debugConnect)
            for connect in connects { connect() }
            return ["pressed": .number(Double(connects.count))]
        case "mode":
            guard only != nil, let mode = params["mode"]?.stringValue.flatMap(RemoteControlMode.init(rawValue:)) else {
                return ["error": "mode needs tab and mode (control or view)"]
            }
            if cloudOnly, mode == .control { return ["error": "only the person takes over (the toolbar's Take over)"] }
            guard let session = tabs.first?.debugSession else { return ["error": "no live session on that tab"] }
            return ["changed": .bool(session.selectMode(mode))]
        case "state":
            var rows: [JSONValue] = []
            for tab in tabs {
                let session: JSONValue = if let live = tab.debugSession { await live.debugState() } else { .null }
                let fields = session.objectValue
                let viewer = fields?["source"]?.stringValue ?? (tab.record?.cloudRd == true ? "rd" : "vnc")
                rows.append(.object([
                    "tab": .string(tab.id.rawValue), "url": tab.state.url.map { .string($0.absoluteString) } ?? .null,
                    "confirm": .bool(tab.debugConnect != nil), "viewer": .string(viewer),
                    "connected": .bool(fields?["state"]?.stringValue == "streaming"),
                    "control": .string(fields?["mode"]?.stringValue == RemoteControlMode.control.rawValue ? "person" : "agent"),
                    "session": session,
                ]))
            }
            return ["tabs": .array(rows)]
        default:
            return ["error": "unknown action"]
        }
    }
}
