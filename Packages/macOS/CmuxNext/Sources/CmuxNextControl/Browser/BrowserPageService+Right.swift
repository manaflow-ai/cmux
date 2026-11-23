public import CmuxNextSettings
import Foundation

/// `browser.page.right` (`cmux browser right <verb>`): the browser in the
/// column right of the Home chat, the one every Chief shows and drives pages
/// in, local or cloud (plans/cmux-next/chief-browser-use-DESIGN.md).
///
/// Params: `agent` (the name its cursor shows; the lease holder), `verb` (the
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
/// column right of the chat the agent's tab is in the agents' own workspace
/// (``BrowserAgentWorkspace``, made once without focus): its own tab there,
/// else a tab there it already drives, else a new one, so the person's Home
/// layout, workspace and focus never change (Leo, 2026-11-22: "product
/// bug/gap, again"); the answer says `surface: "agent_workspace"`. Only a host
/// without that workspace (``BrowserAgentWorkspaceHost``) still answers
/// `not_found` with `dock_pane`.
extension BrowserPageService {
    /// `openBrowser`'s profile value for the clean agent profile: no extensions, no cookies shared
    /// with the person's profiles (plans/cmux-next/passwords.md, section 3.4).
    static let agentBrowserProfileName = "agent"

    /// The agent profile's fixed id, which `openBrowser` creates on first use.
    public static let agentBrowserProfileID = "a9e70000-0000-4000-8000-00000000c0de"

    /// The fixed key of the agents' own browser workspace (``BrowserAgentWorkspace``).
    public static let agentWorkspaceKey = "a9e70000-0000-4000-8000-00000000b0a5"

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
        let agentWorkspaces = agentWorkspaces
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
            guard let column = BrowserRightColumn.resolve(in: call.snapshot.topology) else {
                throw ControlError(code: "not_found", message: ControlStrings.text("control.error.rightNoHome", "No Home workspace"))
            }
            guard let pane = column.pane else {
                if let agentWorkspaces {
                    return try await Self.agentWorkspaceTab(for: agent, url: url, home: column.workspace, call: call, router: router,
                                                            leases: leases, host: agentWorkspaces)
                }
                throw ControlError(code: "not_found",
                                   message: ControlStrings.text("control.error.rightNoColumn",
                                                                "No column right of the Home chat; make one with `cmux pane <dock_pane> split --right`"),
                                   data: ["dock_pane": .string(column.dock.id), "workspace": .string(column.workspace.publicID)])
            }
            func answer(_ tab: String, created: Bool, navigated: Bool, shared: Bool = false) -> JSONValue {
                ["tab": .string(tab), "pane": .string(pane.id), "workspace": .string(column.workspace.publicID),
                 "agent": .string(agent), "created": .bool(created), "navigated": .bool(navigated), "shared": .bool(shared)]
            }
            func held(_ holder: String, _ tab: String) -> ControlError { Self.leaseHeld(holder: holder, tab: tab) }
            // Its own tabs in the agent profile only: one from before in the person's profile
            // (their extensions) would refuse every page call, so a new one opens instead.
            let usable = Set(column.browserTabs.filter { Self.isAgentProfile($0.browserProfileID) }.map(\.id))
            if let own = await leases.openedTab(of: agent, among: usable) {
                if let holder = await leases.acquire(own, for: agent) { throw held(holder, own) }
                return answer(own, created: false, navigated: false)
            }
            // A tab it already drives stays its own, even once another tab is shown.
            if url == nil, let kept = await leases.heldTab(of: agent, among: column.browserTabs.map(\.id)) {
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
            let personIsHere = call.snapshot.topology.focus.paneID == pane.id
            let opened = try await Self.openRightTab(in: pane, url: url, background: personIsHere, call: call, router: router)
            if let holder = await leases.acquire(opened, for: agent, opened: true) { throw held(holder, opened) }
            return answer(opened, created: true, navigated: url != nil)
        }.claimingProgress().withLimit { _, _ in Self.rightOpenLimit }
    }

    /// How long a tab the agents' workspace host made may take to reach the topology.
    static let agentWorkspaceListLimit: Duration = .seconds(5)

    /// The agent's tab in the agents' own workspace (Home has no column right of the chat): its
    /// own tab there, else (no URL) a tab there it already drives, else a new one the host opens,
    /// never shown or focused. A new tab is the agent's own (`opened`), so its next call finds it.
    static func agentWorkspaceTab(for agent: String, url: String?, home: ControlWorkspaceInfo, call: ControlCall,
                                  router: ControlRouter, leases: BrowserTabLeases,
                                  host: any BrowserAgentWorkspaceHost) async throws -> JSONValue {
        func answer(_ tab: String, workspace: ControlWorkspaceInfo?, workspaceKey: String, created: Bool, navigated: Bool) -> JSONValue {
            let pane = workspace.flatMap { BrowserAgentWorkspace(workspace: $0).pane(of: tab) }
            return ["tab": .string(tab), "pane": pane.map { .string($0.id) } ?? .null,
                    "workspace": .string(workspace?.publicID ?? workspaceKey), "agent": .string(agent),
                    "created": .bool(created), "navigated": .bool(navigated), "shared": false,
                    "surface": "agent_workspace"]
        }
        let topology = call.snapshot.topology
        let found = BrowserAgentWorkspace.resolve(in: topology, session: home.sessionID)
        // Its own tab wherever it is now (the person may have moved it or renamed the workspace).
        let outside = BrowserAgentWorkspace.browserTabs(outside: home, in: topology)
        if let own = await leases.openedTab(of: agent, among: outside) {
            if let holder = await leases.acquire(own, for: agent) { throw leaseHeld(holder: holder, tab: own) }
            let at = listing(own, in: topology)
            return answer(own, workspace: at, workspaceKey: at?.id ?? found?.workspace.id ?? BrowserAgentWorkspace.key, created: false, navigated: false)
        }
        if let found, url == nil, let kept = await leases.heldTab(of: agent, among: found.agentTabs.map(\.id)) {
            _ = await leases.acquire(kept, for: agent)
            return answer(kept, workspace: found.workspace, workspaceKey: found.workspace.id, created: false, navigated: false)
        }
        let opened = try await host.openAgentTab(url: url, inWorkspace: found?.workspace.id, named: BrowserAgentWorkspace.name)
        if let holder = await leases.acquire(opened.tab, for: agent, opened: true) { throw leaseHeld(holder: holder, tab: opened.tab) }
        // The page verb the CLI runs next names this tab: wait until the topology lists it.
        let listed = await Self.awaitListed(opened.tab, router: router, within: agentWorkspaceListLimit)
        return answer(opened.tab, workspace: listed, workspaceKey: opened.workspace, created: true, navigated: url != nil)
    }

    /// The workspace listing `tab` once the published topology shows it, nil after `limit`.
    static func awaitListed(_ tab: String, router: ControlRouter, within limit: Duration) async -> ControlWorkspaceInfo? {
        let snapshot = await router.snapshots.snapshot(where: { listing(tab, in: $0.topology) != nil },
                                                       deadline: ContinuousClock.now.advanced(by: limit))
        return snapshot.flatMap { listing(tab, in: $0.topology) }
    }

    /// The workspace whose panes hold `tab`.
    static func listing(_ tab: String, in topology: ControlTopology) -> ControlWorkspaceInfo? {
        topology.workspaces.first { $0.panes.contains { $0.tabs.contains { $0.id == tab } } }
    }

    /// Opens a browser tab in `pane` through `openBrowser` (aimed at a tab of
    /// that pane, without focus; unselected when `background`) and returns its id.
    private static func openRightTab(in pane: ControlPaneInfo, url: String?, background: Bool, call: ControlCall,
                                     router: ControlRouter) async throws -> String {
        guard let anchor = pane.selectedTabID ?? pane.tabs.first?.id else {
            throw ControlError(code: "not_found", message: ControlStrings.text("control.error.rightEmptyColumn", "The column right of the Home chat has no tab to open beside"),
                               data: ["pane": .string(pane.id)])
        }
        var params: [String: JSONValue] = ["action": "openBrowser", "target": .string("tab:" + anchor), "wait": true, "focus": false,
                                           "background": .bool(background)]
        // The agent's own tab: the extension-free agent profile (cmux makes it on first use), so
        // the extension rule never refuses it and the person's profiles and extensions stay theirs.
        var args: [String: JSONValue] = ["profile": .string(agentBrowserProfileName)]
        if let url { args["url"] = .string(url) }
        params["args"] = .object(args)
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
