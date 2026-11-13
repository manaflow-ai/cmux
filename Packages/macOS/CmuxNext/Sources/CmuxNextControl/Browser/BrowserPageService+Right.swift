public import CmuxNextSettings
import Foundation

/// `browser.page.right` (`cmux browser right <verb>`): the browser in the
/// column right of the caller's chat. For a Chief turn (`caller.home_chat`) or
/// no caller that is the column right of the Home chat, the one every Chief
/// shows and drives pages in, local or cloud
/// (plans/cmux-next/chief-browser-use-DESIGN.md). For an agent in a workspace
/// of its own (`caller`: an agent chat outside Home, a terminal) it is that
/// agent's own helper column (ControlCallerPlacement), with the same lease
/// rules, and never Home.
///
/// Params: `caller` (who asks), `agent` (the name its cursor shows; the lease holder), `verb` (the
/// `browser.page.*` method the CLI runs next; absent counts as a write),
/// `url` (the caller navigates: an agent without its own tab there gets a new
/// one with this URL instead of taking the person's tab), `take: true` (the
/// person handed their shown tab over), `release: true` (drop the agent's
/// leases). The answer names the tab the CLI then runs its verb on: `tab`,
/// `pane`, `workspace`, `created`, `navigated` (the new tab already loads
/// `url`), `shared` (the person's tab, for reading only).
///
/// Order: the agent's own tab in that column, else (no URL) a tab there it
/// already drives, else the browser tab the column shows, which a read verb
/// gets without a lease and any other verb only with `take` (else
/// `user_tab`: agents never drive the person's page unasked), else a new tab
/// opened in that column through the `openBrowser` action, never in the
/// chat's dock, never with focus, and unselected while the person's focus is
/// in that pane (plans/cmux-next/agent-browser-passkey-DESIGN.md 3.1). A tab
/// another agent holds answers `lease_held` naming the holder. With no
/// column right of the Home chat it answers `not_found` with `dock_pane`, so
/// the caller makes the column (`cmux pane <dock_pane> split --right`); a
/// workspace agent with no helper column gets its tab in a new column right of
/// it instead (`openBrowser` with its `caller`).
extension BrowserPageService {
    /// `openBrowser`'s profile value for the clean agent profile: no extensions, no cookies shared
    /// with the person's profiles (plans/cmux-next/passwords.md, section 3.4).
    static let agentBrowserProfileName = "agent"

    /// The agent profile's fixed id, which `openBrowser` creates on first use.
    public static let agentBrowserProfileID = "a9e70000-0000-4000-8000-00000000c0de"

    /// True for a tab of the agent profile, or a tab whose profile the topology does not report.
    static func isAgentProfile(_ id: String?) -> Bool {
        guard let id else { return true }
        return id.lowercased() == agentBrowserProfileID
    }

    /// How long an open waits for the new tab (as `browser.open_split`).
    static let rightOpenLimit: Duration = .seconds(20)

    /// The verbs that only read a page: they may run on the person's shown tab.
    static let rightReadVerbs: Set<String> = [
        "browser.page.snapshot", "browser.page.screenshot", "browser.page.state", "browser.page.wait", "browser.page.tabs",
        "browser.page.text", "browser.page.value", "browser.page.passkey_status",
        // Not a read, but it only asks the person: their click runs it.
        "browser.page.passkey",
    ]

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
            let reads = Self.optionalString(call, "verb").map(Self.rightReadVerbs.contains) ?? false
            let take = call.request.params["take"]?.boolValue == true
            let topology = call.snapshot.topology
            guard let column = try BrowserRightColumn.resolve(params: call.request.params, in: topology) else {
                throw ControlError(code: "not_found", message: ControlStrings.text("control.error.rightNoHome", "No Home workspace"))
            }
            guard column.pane != nil || column.caller != nil else {
                throw ControlError(code: "not_found",
                                   message: ControlStrings.text("control.error.rightNoColumn",
                                                                "No column right of the Home chat; make one with `cmux pane <dock_pane> split --right`"),
                                   data: ["dock_pane": .string(column.dock.id), "workspace": .string(column.workspace.publicID)])
            }
            // `pane`: the column's pane; for a workspace agent the pane that holds `tab` (`now`: the topology
            // after an open), since its own tab may be in any pane of its workspace.
            func answer(_ tab: String, in now: ControlTopology? = nil, created: Bool, navigated: Bool, shared: Bool = false) -> JSONValue {
                let holder = column.caller == nil ? nil : (now ?? topology).tab(id: tab)?.pane.id
                return ["tab": .string(tab), "pane": .optional(holder ?? column.pane?.id),
                 "workspace": .string(column.workspace.publicID),
                 "agent": .string(agent), "created": .bool(created), "navigated": .bool(navigated), "shared": .bool(shared)]
            }
            func held(_ holder: String, _ tab: String) -> ControlError { Self.leaseHeld(holder: holder, tab: tab) }
            // Its own tabs in the agent profile only: one from before in the person's profile
            // (their extensions) would refuse every page call, so a new one opens instead.
            let owned = column.ownedTabs
            let usable = Set(owned.filter { Self.isAgentProfile($0.browserProfileID) }.map(\.id))
            if let own = await leases.openedTab(of: agent, among: usable) {
                if let holder = await leases.acquire(own, for: agent) { throw held(holder, own) }
                return answer(own, created: false, navigated: false)
            }
            // A tab it already drives stays its own, even once another tab is shown.
            if url == nil, let kept = await leases.heldTab(of: agent, among: owned.map(\.id)) {
                _ = await leases.acquire(kept, for: agent)
                return answer(kept, created: false, navigated: false)
            }
            if url == nil, let shown = column.shownBrowserTab {
                if take {
                    if let holder = await leases.acquire(shown.id, for: agent) { throw held(holder, shown.id) }
                    return answer(shown.id, created: false, navigated: false)
                }
                if reads { return answer(shown.id, created: false, navigated: false, shared: true) }
                throw ControlError(code: "user_tab",
                                   message: ControlStrings.text("control.error.rightUserTab",
                                                                "The shown tab is the person's: read it, or open your own with `cmux browser right navigate <url>`"),
                                   data: ["tab": .string(shown.id), "url": .string(shown.url ?? "about:blank")])
            }
            let opened: String
            if let caller = column.caller {
                opened = try await Self.openTab(beside: caller, url: url, call: call, router: router)
            } else if let pane = column.pane {
                opened = try await Self.openRightTab(in: pane, url: url, background: topology.focus.paneID == pane.id, call: call, router: router)
            } else {
                throw ControlError(code: "not_found", message: ControlStrings.text("control.error.rightNoHome", "No Home workspace"))
            }
            if let holder = await leases.acquire(opened, for: agent, opened: true) { throw held(holder, opened) }
            return answer(opened, in: router.snapshots.current.topology, created: true, navigated: url != nil)
        }.claimingProgress().withLimit { _, _ in Self.rightOpenLimit }
    }

    /// Opens a browser tab in `pane` through `openBrowser` (aimed at a tab of
    /// that pane, without focus; unselected when `background`) and returns its id.
    private static func openRightTab(in pane: ControlPaneInfo, url: String?, background: Bool, call: ControlCall,
                                     router: ControlRouter) async throws -> String {
        guard let anchor = pane.selectedTabID ?? pane.tabs.first?.id else {
            throw ControlError(code: "not_found", message: ControlStrings.text("control.error.rightEmptyColumn", "The column right of the Home chat has no tab to open beside"),
                               data: ["pane": .string(pane.id)])
        }
        let id = pane.id
        let panes: @Sendable (ControlTopology) -> [ControlPaneInfo] = { now in
            now.workspaces.flatMap(\.screens).flatMap(\.panes).filter { $0.id == id }
        }
        return try await openAgentTab(["target": .string("tab:" + anchor), "background": .bool(background)], url: url, in: panes,
                                      call: call, router: router)
    }

    /// Opens a workspace agent's own tab through `openBrowser` with its `caller` and no target, so `action.run`
    /// places it by the one rule (``ControlCallerPlacement``): in its helper column, else in a new column right
    /// of it; behind the terminal in the own pane of a terminal no agent runs in. Returns its id.
    private static func openTab(beside caller: ControlCallerPlacement, url: String?, call: ControlCall,
                                router: ControlRouter) async throws -> String {
        var params: [String: JSONValue] = ["caller": caller.location.caller.json]
        if !caller.isBeside { params["background"] = true }
        let workspace = caller.location.workspace.id
        let panes: @Sendable (ControlTopology) -> [ControlPaneInfo] = { now in now.workspaces.first { $0.id == workspace }?.panes ?? [] }
        return try await openAgentTab(params, url: url, in: panes, call: call, router: router)
    }

    /// Runs `openBrowser` with `placing` (its target or caller) in the extension-free agent profile, without
    /// focus, and returns the browser tab it made among `panes` of the topology after the run.
    private static func openAgentTab(_ placing: [String: JSONValue], url: String?,
                                     in panes: @escaping @Sendable (ControlTopology) -> [ControlPaneInfo], call: ControlCall,
                                     router: ControlRouter) async throws -> String {
        var params: [String: JSONValue] = ["action": "openBrowser", "wait": true, "focus": false]
        params.merge(placing) { _, placed in placed }
        // The agent's own tab: the extension-free agent profile (cmux makes it on first use), so
        // the extension rule never refuses it and the person's profiles and extensions stay theirs.
        var args: [String: JSONValue] = ["profile": .string(agentBrowserProfileName)]
        if let url { args["url"] = .string(url) }
        params["args"] = .object(args)
        if let origin = call.request.params["origin"] { params["origin"] = origin }
        if let key = call.request.params["idempotency_key"] { params["idempotency_key"] = key }
        func browsers(_ topology: ControlTopology) -> Set<String> {
            Set(panes(topology).flatMap(\.tabs).filter { $0.kind == "browser" }.map(\.id))
        }
        let before = browsers(call.snapshot.topology)
        let request = ControlRequest(id: call.request.id, method: call.method, params: params)
        let run = try await router.runAction(ControlCall(request: request, snapshot: call.snapshot, connection: call.connection,
                                                         deadline: call.deadline, progress: call.progress, engineStartMark: call.engineStartMark))
        let now = browsers(router.snapshots.current.topology)
        let created = run["created"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let tab = created.first(where: { now.contains($0) }) ?? now.subtracting(before).sorted().first {
            return tab
        }
        throw ControlError(code: "operation_failed",
                           message: ControlStrings.format("control.error.createdNoSurface", "%@: the action ran but created no surface", call.method))
    }
}
