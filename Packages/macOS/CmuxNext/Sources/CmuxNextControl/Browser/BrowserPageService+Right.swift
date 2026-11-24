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
/// column right of the chat the new tab opens beside the person's current tab
/// (any workspace, unselected), and while the person is in the Home chat
/// itself in a new column right of it (``openPlace(column:topology:)``); the
/// agent's own tab is then found wherever it is. Leo 2026-11-23: "you should
/// be able to simply open it to the left or right of your current tab or pane
/// or split depending".
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
            guard let column = BrowserRightColumn.resolve(in: call.snapshot.topology) else {
                throw ControlError(code: "not_found", message: ControlStrings.text("control.error.rightNoHome", "No Home workspace"))
            }
            let topology = call.snapshot.topology
            func answer(_ tab: String, created: Bool, navigated: Bool, shared: Bool = false) -> JSONValue {
                let now = router.snapshots.current.topology
                let place = Self.place(of: tab, in: now) ?? Self.place(of: tab, in: topology)
                return ["tab": .string(tab), "pane": .optional(place?.pane ?? column.pane?.id),
                        "workspace": .string(place?.workspace ?? column.workspace.publicID),
                        "agent": .string(agent), "created": .bool(created), "navigated": .bool(navigated), "shared": .bool(shared)]
            }
            func held(_ holder: String, _ tab: String) -> ControlError { Self.leaseHeld(holder: holder, tab: tab) }
            // With no column right of the Home chat the agent's tabs live beside the person's tab
            // (below), so its own and held tabs are looked up wherever they are.
            let candidates = column.pane == nil ? Self.allBrowserTabs(in: topology) : column.browserTabs
            // Its own tabs in the agent profile only: one from before in the person's profile
            // (their extensions) would refuse every page call, so a new one opens instead.
            let usable = Set(candidates.filter { Self.isAgentProfile($0.browserProfileID) }.map(\.id))
            if let own = await leases.openedTab(of: agent, among: usable) {
                if let holder = await leases.acquire(own, for: agent) { throw held(holder, own) }
                return answer(own, created: false, navigated: false)
            }
            // A tab it already drives stays its own, even once another tab is shown.
            if url == nil, let kept = await leases.heldTab(of: agent, among: candidates.map(\.id)) {
                _ = await leases.acquire(kept, for: agent)
                return answer(kept, created: false, navigated: false)
            }
            if url == nil, column.pane != nil, let shown = column.shownBrowserTab {
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
            let opened = try await Self.openRightTab(Self.openPlace(column: column, topology: topology), url: url, call: call, router: router)
            if let holder = await leases.acquire(opened, for: agent, opened: true) { throw held(holder, opened) }
            return answer(opened, created: true, navigated: url != nil)
        }.claimingProgress().withLimit { _, _ in Self.rightOpenLimit }
    }

    /// Where a new agent tab opens. Leo 2026-11-23: "you should be able to simply open it to the left
    /// or right of your current tab or pane or split depending".
    enum OpenPlace: Equatable {
        /// Beside `anchor` in `pane` (the column right of the Home chat, or the person's focused pane);
        /// unselected when `background` (the person works in that pane).
        case beside(anchor: String, pane: String, background: Bool)
        /// A new column right of the Home chat (the person is in the chat, or nothing has focus).
        case besideHomeChat
    }

    /// The column right of the Home chat when there is one; else beside the person's current tab, in
    /// any workspace, when it is not the Home chat itself; else a new column right of the Home chat.
    static func openPlace(column: BrowserRightColumn, topology: ControlTopology) -> OpenPlace {
        let focus = topology.focus
        if let pane = column.pane, let anchor = pane.selectedTabID ?? pane.tabs.first?.id {
            return .beside(anchor: anchor, pane: pane.id, background: focus.paneID == pane.id)
        }
        let panes = topology.workspaces.lazy.flatMap(\.screens).flatMap(\.panes)
        if let id = focus.paneID, id != column.dock.id, let pane = panes.first(where: { $0.id == id }),
           !pane.tabs.contains(where: { $0.page == "home-dock" }),
           let anchor = focus.tabID.flatMap({ tab in pane.tabs.contains { $0.id == tab } ? tab : nil })
            ?? pane.selectedTabID ?? pane.tabs.first?.id {
            return .beside(anchor: anchor, pane: pane.id, background: true)
        }
        return .besideHomeChat
    }

    /// Every app browser tab, any workspace.
    static func allBrowserTabs(in topology: ControlTopology) -> [ControlTabInfo] {
        topology.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).filter { $0.kind == "browser" && $0.page == nil }
    }

    /// The pane and public workspace id holding `tab`.
    static func place(of tab: String, in topology: ControlTopology) -> (pane: String, workspace: String)? {
        for workspace in topology.workspaces {
            for screen in workspace.screens {
                if let pane = screen.panes.first(where: { $0.tabs.contains { $0.id == tab } }) { return (pane.id, workspace.publicID) }
            }
        }
        return nil
    }

    /// Opens a browser tab at `place` through `openBrowser` (never with focus) and returns its id.
    private static func openRightTab(_ place: OpenPlace, url: String?, call: ControlCall, router: ControlRouter) async throws -> String {
        var params: [String: JSONValue] = ["action": "openBrowser", "wait": true, "focus": false]
        switch place {
        case let .beside(anchor, _, background):
            params["target"] = .string("tab:" + anchor)
            params["background"] = .bool(background)
        case .besideHomeChat:
            // The Home chat as the caller: the app opens a new column right of it, never in its dock.
            params["caller"] = ["home_chat": true]
        }
        // The agent's own tab: the extension-free agent profile (cmux makes it on first use), so
        // the extension rule never refuses it and the person's profiles and extensions stay theirs.
        var args: [String: JSONValue] = ["profile": .string(agentBrowserProfileName)]
        if let url { args["url"] = .string(url) }
        params["args"] = .object(args)
        if let origin = call.request.params["origin"] { params["origin"] = origin }
        if let key = call.request.params["idempotency_key"] { params["idempotency_key"] = key }
        let before = Set(allBrowserTabs(in: call.snapshot.topology).map(\.id))
        let request = ControlRequest(id: call.request.id, method: call.method, params: params)
        let run = try await router.runAction(ControlCall(request: request, snapshot: call.snapshot, connection: call.connection,
                                                         deadline: call.deadline, progress: call.progress, engineStartMark: call.engineStartMark))
        let browsers = Set(allBrowserTabs(in: router.snapshots.current.topology).map(\.id))
        let created = run["created"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let tab = created.first(where: { browsers.contains($0) }) ?? browsers.subtracting(before).sorted().first {
            return tab
        }
        throw ControlError(code: "operation_failed",
                           message: ControlStrings.format("control.error.createdNoSurface", "%@: the action ran but created no surface", call.method))
    }
}
