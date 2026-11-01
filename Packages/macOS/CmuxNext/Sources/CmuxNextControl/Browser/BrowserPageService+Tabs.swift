public import CmuxNextSettings
import Foundation

/// `browser.page.tabs|new_tab|select_tab|close`: the old `cmux browser tab
/// list|new|switch|close`. Open, select and close run the registry actions
/// the keyboard, menu and `cmux tab …` run (`openBrowser`, `tab.focus`,
/// `closeTab`) with `action.run`'s contract, on a tab checked to be an app
/// browser tab first, so `page` never closes a focused terminal. The
/// request's `idempotency_key` goes with it, so a retried run is one run.
extension BrowserPageService {
    func tabMethods(router: ControlRouter) -> [ControlMethod] {
        [
            .snapshot("browser.page.tabs") { call in try Self.tabList(call) },
            tabAction("new_tab", "openBrowser", router: router) { call in
                call.request.params["url"]?.stringValue.flatMap { $0.isEmpty ? nil : ["url": .string($0)] } ?? [:]
            },
            tabAction("select_tab", "tab.focus", router: router) { _ in [:] },
            tabAction("close", "closeTab", router: router) { _ in [:] },
        ]
    }

    private func tabAction(_ name: String, _ action: String, router: ControlRouter,
                           _ arguments: @escaping @Sendable (ControlCall) -> [String: JSONValue]) -> ControlMethod {
        .async("browser.page.\(name)") { [weak router] call in
            guard let router else { throw ControlRouter.stopped }
            var fingerprintParams = call.params
            for key in ["idempotency_key", "wait", "after"] { fingerprintParams.removeValue(forKey: key) }
            return try await router.runAction(call, fingerprint: .page(method: call.method, params: fingerprintParams, callerApp: call.request.callerApp)) {
                var params: [String: JSONValue] = ["action": .string(action), "wait": call.request.params["wait"] ?? true]
                var tab: Tab?
                if name == "new_tab", let lonely = try Self.callerWithNoBrowserNear(call) {
                    // The caller's first browser: an agent's opens beside its chat, a terminal's
                    // in its own pane behind it, so the agent running there stays in view.
                    if lonely.caller.agentSession != nil || lonely.caller.homeChat {
                        params["caller"] = call.request.params["caller"]
                    } else {
                        params["target"] = .string("tab:" + lonely.location.tab.id)
                        params["background"] = true
                    }
                } else {
                    let anchor = try Self.tab(call)
                    params["target"] = .string("tab:" + anchor.id)
                    tab = anchor
                }
                let args = arguments(call)
                if !args.isEmpty { params["args"] = .object(args) }
                let request = ControlRequest(id: call.request.id, method: call.method, params: params, callerApp: call.request.callerApp)
                let derived = ControlCall(request: request, snapshot: call.snapshot, connection: call.connection,
                                          deadline: call.deadline, progress: call.progress, engineStartMark: call.engineStartMark)
                let base = tab.map(Self.base) ?? [:]
                return (derived, { run in
                    var result = base
                    for key in ["ran", "waited", "created"] { result.updateValue(run[key] ?? .null, forKey: key) }
                    if let sequence = run["sequence"] { result["sequence"] = sequence }
                    return .object(result)
                })
            }
        }.claimingProgress()
    }

    /// The caller of a call that names no tab, when no browser is near it (``BrowserCallerTarget``).
    static func callerWithNoBrowserNear(_ call: ControlCall) throws -> (caller: ControlCaller, location: ControlCallerLocation)? {
        let params = call.request.params
        guard params["tab"]?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty ?? true,
              let location = try BrowserCallerTarget.callerLocation(params: params, in: call.snapshot.topology),
              BrowserCallerTarget.resolve(near: location, in: call.snapshot.topology) == nil else { return nil }
        return (location.caller, location)
    }

    /// The app browser tabs of one workspace: the named browser tab's, else
    /// that of the browser nearest the caller (`caller`, else its own), else
    /// the focused workspace's; `all: true` lists every workspace.
    static func tabList(_ call: ControlCall) throws -> JSONValue {
        let topology = call.snapshot.topology
        let params = call.request.params
        let all = params["all"]?.boolValue == true
        var workspaceID = topology.focus.workspaceID
        if !all, let requested = params["tab"]?.stringValue, !requested.isEmpty {
            // An explicit tab wins over caller context, including one that has since closed.
            let anchor = try tab(call).id
            workspaceID = topology.workspaces.first { $0.screens.contains { $0.panes.contains { $0.tabs.contains { $0.id == anchor } } } }?.id
        } else if !all, let location = try BrowserCallerTarget.callerLocation(params: params, in: topology) {
            // A stale caller cannot make a tab list jump to the person's current workspace.
            workspaceID = (BrowserCallerTarget.resolve(near: location, in: topology)?.workspace ?? location.workspace).id
        }
        var tabs: [JSONValue] = []
        for workspace in topology.workspaces where all || workspace.id == workspaceID {
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs where tab.kind == "browser" {
                        tabs.append([
                            "id": .string(tab.id), "title": .string(tab.name ?? tab.title), "url": .optional(tab.url),
                            "workspace": .string(workspace.publicID), "pane": .string(pane.id),
                            "selected": .bool(pane.selectedTabID == tab.id), "focused": .bool(topology.focus.tabID == tab.id),
                        ])
                    }
                }
            }
        }
        return ["tabs": .array(tabs)]
    }
}
