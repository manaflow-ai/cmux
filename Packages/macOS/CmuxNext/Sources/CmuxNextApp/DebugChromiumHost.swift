import CmuxNextBrowser
import CmuxNextControl
import CmuxNextSettings

/// `debug.chromium_host` {op: open {url, pane?, focus?} | close | kill | report} and
/// `debug.chromium_host.measure` {op: ping {count} | input} (DEBUG builds, with
/// `browserHost.helperPrototype` on): ``ChromiumHostPrototype`` over a pane's content
/// (default: the focused pane). plans/cmux-next/cef-helper-app-DESIGN.md.
enum DebugChromiumHost {
    static func register(on router: ControlRouter?, services: AppServices) {
        #if DEBUG
        let host = ChromiumHostPrototype { ChromiumHostPrototype.bundledConfiguration() }
        router?.register([
            .mainActor("debug.chromium_host") { [weak services] call in
                let params = call.params
                switch params["op"]?.stringValue {
                case "open":
                    guard let services, let controller = services.windows.controllers.first,
                          let key = params["pane"]?.stringValue ?? controller.focus.state.pane,
                          let pane = controller.content?.paneController(key: key) else { return .value(["error": "no pane"]) }
                    return .value(JSONValue(foundation: host.open(params["url"]?.stringValue ?? "", over: pane.view.contentHost,
                                                                  focus: params["focus"]?.boolValue != false)) ?? .null)
                case "close": return .value(JSONValue(foundation: host.close()) ?? .null)
                case "kill": return .value(JSONValue(foundation: host.kill()) ?? .null)
                default: return .value(JSONValue(foundation: host.report) ?? .null)
                }
            },
            .async("debug.chromium_host.measure") { call in
                let fields = call.params["op"]?.stringValue == "ping"
                    ? await host.ping(count: call.params["count"]?.intValue ?? 200)
                    : await host.inputStats()
                guard let fields else { return ["error": "no running Chromium host"] }
                return .object(fields.mapValues(JSONValue.number))
            }.withDeadline(.fixed(.seconds(60))),
        ])
        #endif
    }
}
