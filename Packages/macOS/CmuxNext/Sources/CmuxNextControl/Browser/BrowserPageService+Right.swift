public import CmuxNextSettings
import Foundation

/// `browser.page.right` (`cmux browser right <verb>`): the browser in the
/// column right of the Home chat, the one every Chief shows and drives pages
/// in, local or cloud (plans/cmux-next/chief-browser-use-DESIGN.md).
///
/// Params: `agent` (the name its cursor shows; the lease holder), `url` (the
/// caller navigates: an agent without its own tab there gets a new one with
/// this URL instead of taking the user's tab), `release: true` (drop the
/// agent's leases). The answer names the tab the CLI then runs its verb on:
/// `tab`, `pane`, `workspace`, `created`, `navigated` (the new tab already
/// loads `url`).
///
/// Order: the agent's own tab in that column, else (no URL) a tab there it
/// already drives, else the browser tab the column shows, else a new tab opened in that column through the
/// `openBrowser` action, never in the chat's dock and never with focus. A tab
/// another agent holds answers `lease_held` naming the holder. With no
/// column right of the chat it answers `not_found` with `dock_pane`, so the
/// caller makes the column (`cmux pane <dock_pane> split --right`).
extension BrowserPageService {
    /// How long an open waits for the new tab (as `browser.open_split`).
    static let rightOpenLimit: Duration = .seconds(20)

    func rightMethod(router: ControlRouter) -> ControlMethod {
        let leases = leases
        return .async("browser.page.right") { [weak router] call in
            guard let router else { throw ControlRouter.stopped }
            let agent = Self.optionalString(call, "agent") ?? "agent"
            if call.request.params["release"]?.boolValue == true {
                let held = await leases.release(agent)
                return ["agent": .string(agent), "released": .array(held.map(JSONValue.string))]
            }
            let url = Self.optionalString(call, "url")
            guard let column = BrowserRightColumn.resolve(in: call.snapshot.topology) else {
                throw ControlError(code: "not_found", message: ControlStrings.text("control.error.rightNoHome", "No Home workspace"))
            }
            guard let pane = column.pane else {
                throw ControlError(code: "not_found",
                                   message: ControlStrings.text("control.error.rightNoColumn",
                                                                "No column right of the Home chat; make one with `cmux pane <dock_pane> split --right`"),
                                   data: ["dock_pane": .string(column.dock.id), "workspace": .string(column.workspace.publicID)])
            }
            func answer(_ tab: String, created: Bool, navigated: Bool) -> JSONValue {
                ["tab": .string(tab), "pane": .string(pane.id), "workspace": .string(column.workspace.publicID),
                 "agent": .string(agent), "created": .bool(created), "navigated": .bool(navigated)]
            }
            func held(_ holder: String, _ tab: String) -> ControlError {
                ControlError(code: "lease_held",
                             message: ControlStrings.format("control.error.rightLeaseHeld",
                                                            "%@ is driving this tab; wait, or open your own tab with a URL", holder),
                             data: ["holder": .string(holder), "tab": .string(tab)])
            }
            if let own = await leases.openedTab(of: agent, among: Set(column.browserTabs.map(\.id))) {
                if let holder = await leases.acquire(own, for: agent) { throw held(holder, own) }
                return answer(own, created: false, navigated: false)
            }
            // A tab it already drives stays its own, even once another tab is shown.
            if url == nil, let kept = await leases.heldTab(of: agent, among: column.browserTabs.map(\.id)) {
                _ = await leases.acquire(kept, for: agent)
                return answer(kept, created: false, navigated: false)
            }
            if url == nil, let shown = column.shownBrowserTab {
                if let holder = await leases.acquire(shown.id, for: agent) { throw held(holder, shown.id) }
                return answer(shown.id, created: false, navigated: false)
            }
            let opened = try await Self.openRightTab(in: pane, url: url, call: call, router: router)
            if let holder = await leases.acquire(opened, for: agent, opened: true) { throw held(holder, opened) }
            return answer(opened, created: true, navigated: url != nil)
        }.claimingProgress().withLimit { _, _ in Self.rightOpenLimit }
    }

    /// Opens a browser tab in `pane` through `openBrowser` (aimed at a tab of
    /// that pane, without focus) and returns its id.
    private static func openRightTab(in pane: ControlPaneInfo, url: String?, call: ControlCall, router: ControlRouter) async throws -> String {
        guard let anchor = pane.selectedTabID ?? pane.tabs.first?.id else {
            throw ControlError(code: "not_found", message: ControlStrings.text("control.error.rightEmptyColumn", "The column right of the Home chat has no tab to open beside"),
                               data: ["pane": .string(pane.id)])
        }
        var params: [String: JSONValue] = ["action": "openBrowser", "target": .string("tab:" + anchor), "wait": true, "focus": false]
        if let url { params["args"] = ["url": .string(url)] }
        if let origin = call.request.params["origin"] { params["origin"] = origin }
        if let key = call.request.params["idempotency_key"] { params["idempotency_key"] = key }
        let before = Set(pane.tabs.map(\.id))
        let request = ControlRequest(id: call.request.id, method: call.method, params: params)
        let run = try await router.runAction(ControlCall(request: request, snapshot: call.snapshot, connection: call.connection,
                                                         deadline: call.deadline, progress: call.progress, engineStartMark: call.engineStartMark))
        let now = router.snapshots.current.topology
        let paneNow = now.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).first { $0.id == pane.id }
        let browsers = Set((paneNow?.tabs ?? []).filter { $0.kind == "browser" }.map(\.id))
        let created = run["created"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let tab = created.first(where: { browsers.contains($0) }) ?? browsers.subtracting(before).sorted().first {
            return tab
        }
        throw ControlError(code: "operation_failed",
                           message: ControlStrings.format("control.error.createdNoSurface", "%@: the action ran but created no surface", call.method))
    }
}
