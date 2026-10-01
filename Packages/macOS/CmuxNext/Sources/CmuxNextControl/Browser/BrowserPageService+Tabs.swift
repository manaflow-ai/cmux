public import CmuxNextSettings
import Foundation

/// `browser.page.tabs|new_tab|select|close`: the old `cmux browser tab
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
            tabAction("select", "tab.focus", router: router) { _ in [:] },
            tabAction("close", "closeTab", router: router) { _ in [:] },
        ]
    }

    private func tabAction(_ name: String, _ action: String, router: ControlRouter,
                           _ arguments: @escaping @Sendable (ControlCall) -> [String: JSONValue]) -> ControlMethod {
        .async("browser.page.\(name)") { [weak router] call in
            guard let router else { throw ControlRouter.stopped }
            let tab = try Self.tab(call)
            var params: [String: JSONValue] = ["action": .string(action), "target": .string("tab:" + tab.id),
                                               "wait": call.request.params["wait"] ?? true]
            if let key = call.request.params["idempotency_key"] { params["idempotency_key"] = key }
            let args = arguments(call)
            if !args.isEmpty { params["args"] = .object(args) }
            let request = ControlRequest(id: call.request.id, method: call.method, params: params)
            let run = try await router.runAction(ControlCall(request: request, snapshot: call.snapshot, connection: call.connection,
                                                             deadline: call.deadline, progress: call.progress))
            var result = Self.base(tab)
            for key in ["ran", "waited", "created"] { result[key] = run[key] ?? .null }
            if let sequence = run["sequence"] { result["sequence"] = sequence }
            return .object(result)
        }.claimingProgress()
    }

    /// The app browser tabs of one workspace: the named browser tab's, else
    /// the focused workspace's; `all: true` lists every workspace.
    static func tabList(_ call: ControlCall) throws -> JSONValue {
        let topology = call.snapshot.topology
        let params = call.request.params
        let all = params["all"]?.boolValue == true
        var workspaceID = topology.focus.workspaceID
        if !all, let requested = params["tab"]?.stringValue, !requested.isEmpty {
            let anchor = try tab(call).id
            workspaceID = topology.workspaces.first { $0.screens.contains { $0.panes.contains { $0.tabs.contains { $0.id == anchor } } } }?.id
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
