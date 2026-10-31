import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
import Foundation

extension TabLifecycle {
    /// Tools opened by a person from the chat dock are placed before Auto Layout: its strip is
    /// the right column, regardless of which strip pane was focused last or the tiling setting.
    /// The working directory comes from the chat, never from the terminal above the new split.
    static func openTerminalFromDock(_ ctx: AppActionContext, _ invocation: ActionInvocation, pane: PaneModel,
                                     cwd: String?, keep: Bool?) -> Bool {
        guard invocation.origin == .user, !invocation.besideCaller,
              let chat = ctx.services.paneController(for: pane) else { return false }
        let start = cwd ?? NewTerminalStart.uninherited(.tab, services: ctx.services, daemon: chat.daemon, besides: chat.selectedTab)
            ?? NewTerminalStart.inherited(besides: chat.selectedTab, in: pane, services: ctx.services)
        return ChatColumnPlacement.openTool(from: chat, services: ctx.services) { target, placed in
            guard target.daemon.connection != nil else { return false }
            let then = placed ?? NewTabSlot.placing(after: target.selectedTab, services: ctx.services, then: nil)
            target.newTerminalTab(cwd: start, keep: keep, daemonResolvesCwd: true, then: then)
            return true
        }
    }

    /// A browser uses the same serialized right-column open as a terminal. Preserve the chat's
    /// working URL and the requested profile; while a split is being made, its upper pane keeps
    /// showing its existing tab and the browser appears only after its move below lands.
    static func openBrowserFromDock(_ ctx: AppActionContext, _ invocation: ActionInvocation, pane: PaneModel,
                                    url: URL?, engine: String?, profile: AgentBrowserProfile.Request) -> Bool {
        guard invocation.origin == .user, !invocation.besideCaller,
              let chat = ctx.services.paneController(for: pane) else { return false }
        return ChatColumnPlacement.openTool(from: chat, services: ctx.services, background: invocation.opensInBackground) { target, placed in
            let then = placed ?? NewTabSlot.placing(after: target.selectedTab, services: ctx.services, then: nil)
            let background = placed != nil || invocation.opensInBackground
            switch profile {
            case .cascade:
                if url == nil {
                    chat.newBrowserTabFromSelectedTab(engine: engine, in: target, background: background, then: then)
                    return true
                }
                return target.newBrowserTab(url: url, engine: engine, background: background, then: then)
            case .explicit(let id):
                return target.newBrowserTab(url: url, engine: engine, background: background, profile: id, then: then)
            case .agent:
                let profiles = ctx.services.browserProfiles
                ctx.registry.track(Task { @MainActor in
                    do {
                        let id = try await AgentBrowserProfile.ensure(profiles)
                        target.newBrowserTab(url: url, engine: engine, background: background, profile: id, then: then)
                        return nil
                    } catch {
                        return "agent-browser-profile: \(error)"
                    }
                })
                return true
            }
        }
    }
}
