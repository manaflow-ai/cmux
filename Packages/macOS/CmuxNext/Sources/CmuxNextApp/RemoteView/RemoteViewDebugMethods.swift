import CmuxNextControl
import CmuxNextSettings
import CmuxNextRemoteView
import CmuxNextRemoteViewSessions
import Foundation

/// `remote_view.state`, `remote_view.connect` and `remote_view.mode` (every build): the live
/// Cloud desktop tabs (``RemoteViewTabsControl``, `cloudOnly`). `debug.remote_view` (development
/// builds): every remote view tab, for live checks of the desktop pane (cx-wb5.75), with the same
/// actions plus `open` {url, pane?}, which opens `url` (a `cmux://remote-view` record) in a new tab
/// of `pane`, else the active window's focused pane, else the first window's. Connect stands in
/// for the person's click; control input still comes only from the person's own pane.
/// Registers them here (not an `AppControl` extension: that type is over its god-type budget).
struct RemoteViewDebugMethods {
    let services: AppServices

    func register(on router: ControlRouter?) {
        router?.register(["state", "connect", "mode"].map { action in
            .async("remote_view.\(action)") { call in
                var params = call.params
                params["action"] = .string(action)
                return await RemoteViewTabsControl.answer(params, cloudOnly: true)
            }
        })
        #if DEBUG
        let services = self.services
        router?.register([
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
    guard params["action"]?.stringValue == "open" else {
        var answer = await RemoteViewTabsControl.answer(params, cloudOnly: false)
        if case var .object(fields) = answer, fields["tabs"] != nil {
            fields["rd_debug_problem"] = RemoteViewDebugRdHost.problem().map(JSONValue.string) ?? .null
            answer = .object(fields)
        }
        return answer
    }
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
}
#endif
