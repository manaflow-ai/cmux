import Foundation

public extension ControlCall {
    /// The tab an agent's request opens beside (`browser.open_link` with no `terminal_id`): its
    /// chat tab, the Home chat for a Chief turn, or, for an agent whose chat no tab shows, a tab
    /// in the workspace its session runs in (`caller.workspace`, ControlCallerLocation). Nil when
    /// the request names no agent caller. An agent cmux cannot place is `caller_unavailable`:
    /// its page never opens beside the focused pane, which is Home while the person talks to the
    /// Chief (user, 2026-11-18).
    func agentCallerTab() throws -> String? {
        guard let caller = try ControlCaller(params), caller.agentSession != nil || caller.homeChat else { return nil }
        guard let location = ControlCallerLocation.resolve(caller, in: snapshot.topology) else {
            throw BrowserCallerTarget.missingCaller(caller)
        }
        return location.tab.id
    }

    /// The tab a link from `browser.open_link` opens beside: the caller's terminal tab when the
    /// request names a terminal (`terminal_id`, `tab` from ``terminalTab(_:)``), else
    /// ``agentCallerTab()``: an agent with no terminal (its chat's shell, the `BROWSER` and `open`
    /// shims) opens beside its own chat, never in the focused pane.
    func linkSourceTab(terminal: String?, tab: String?) throws -> String? {
        terminal == nil ? try agentCallerTab() : tab
    }
}
