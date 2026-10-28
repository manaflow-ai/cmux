public import CmuxNextSettings
import Foundation

/// `browser.page.mirror` (`cmux browser <tab_…> mirror [--pane <pane>] [--off]`):
/// lists a browser tab in a second pane too, by default the column right of
/// the Home chat, so the person watches an agent's tab live from Home while
/// the tab stays in the agent's workspace (plans/cmux-next/shared-browser-tabs.md).
///
/// Params: `tab` (the browser tab), `pane` (the pane the mirror goes to;
/// default Home's right column), `off: true` (take the mirror out of `pane`,
/// or out of every pane). The answer: `tab`, `pane`, `mirrored`.
///
/// It shows a page and drives nothing, so it takes no lease. The mirror is
/// selected unless the person's focus is in that pane (the rule of a new
/// agent tab there, agent-browser-passkey-DESIGN.md 3.1).
///
/// The Home mirror: the first write an agent makes on a tab outside the Home
/// workspace mirrors that tab into Home's right column (``leasing(_:)``), and
/// the agent's next such tab replaces its earlier mirror, so Home lists at
/// most one mirror per agent and the person sees every agent's browser
/// without opening its workspace. A tab is mirrored once: a mirror the person
/// closed does not come back when the agent writes again after a pause.
extension BrowserPageService {
    func mirrorMethod() -> ControlMethod {
        let mirrors = mirrors
        return .async("browser.page.mirror") { call in
            guard let mirrors else {
                throw ControlError(code: "unavailable",
                                   message: ControlStrings.text("control.error.mirrorUnavailable", "This app cannot show a tab in a second pane"))
            }
            let tab = try Self.tab(call)
            let named = Self.optionalString(call, "pane")
            if call.request.params["off"]?.boolValue == true {
                let left = await mirrors.unmirror(tab: tab.id, from: named)
                var answer = Self.base(tab)
                answer["mirrored"] = false
                answer["panes"] = .array(left.map(JSONValue.string))
                return .object(answer)
            }
            let pane: String
            if let named {
                pane = named
            } else if let column = BrowserRightColumn.resolve(in: call.snapshot.topology), let right = column.pane {
                pane = right.id
            } else {
                throw ControlError(code: "not_found",
                                   message: ControlStrings.text("control.error.rightNoColumn",
                                                                "No column right of the Home chat; make one with `cmux pane <dock_pane> split --right`"))
            }
            let panes = call.snapshot.topology.workspaces.lazy.flatMap(\.screens).flatMap(\.panes)
            guard let target = panes.first(where: { $0.id == pane }) else {
                throw ControlError(code: "not_found", message: ControlStrings.format("control.error.mirrorNoPane", "No pane %@", pane))
            }
            guard !target.tabs.contains(where: { $0.id == tab.id }) else {
                throw ControlError.invalidParams(ControlStrings.text("control.error.mirrorOwnPane", "The tab is already in that pane"))
            }
            let select = call.snapshot.topology.focus.paneID != pane
            guard await mirrors.mirror(tab: tab.id, into: pane, select: select) else {
                throw ControlError(code: "not_found", message: ControlStrings.format("control.error.mirrorNoPane", "No pane %@", pane))
            }
            var answer = Self.base(tab)
            answer["pane"] = .string(pane)
            answer["mirrored"] = true
            return .object(answer)
        }
    }

    /// Mirrors `tab` into Home's right column for `agent`, which just started
    /// driving it, unless the tab is in the Home workspace already or Home has
    /// no right column. The agent's earlier Home mirror goes.
    static func mirrorIntoHome(_ tab: Tab, for agent: String, call: ControlCall, mirrors: any BrowserTabMirrorHost,
                               leases: BrowserTabLeases) async {
        let topology = call.snapshot.topology
        guard let column = BrowserRightColumn.resolve(in: topology), let pane = column.pane else { return }
        let home = column.workspace.screens.lazy.flatMap(\.panes)
        guard !home.contains(where: { $0.tabs.contains { $0.id == tab.id } || $0.mirroredTabIDs.contains(tab.id) }) else { return }
        let earlier = await leases.noteHomeMirror(tab.id, for: agent)
        // Once per tab: a mirror the person closed, or moved off, stays so after the agent's pauses.
        guard earlier != tab.id else { return }
        if let earlier { _ = await mirrors.unmirror(tab: earlier, from: pane.id) }
        _ = await mirrors.mirror(tab: tab.id, into: pane.id, select: topology.focus.paneID != pane.id)
    }
}
