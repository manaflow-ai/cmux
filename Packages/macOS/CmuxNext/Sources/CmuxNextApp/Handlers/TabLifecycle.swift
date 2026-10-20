import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import enum CmuxNextLayout.ChatColumnPlacement
import enum CmuxNextLayout.NewChatPlacement

/// New terminal tab, new browser tab, and close tab for a shown pane (the
/// strip's optimistic path) or any daemon pane, so the CLI can act on a
/// workspace no window shows. Every daemon command is tracked
/// (`ActionRegistry.track`) for callers that await the effect.
enum TabLifecycle {
    static func newTerminal(_ ctx: AppActionContext, _ invocation: ActionInvocation, after anchor: TabModel? = nil) {
        #if DEBUG
        if NewTerminalTrace.shared.isArmed { NewTerminalTrace.shared.markAction() } // `debug.new_terminal_trace`
        #endif
        guard let focused = ctx.daemonPane(invocation) else { return }
        let cwd = invocation["cwd"]?.stringValue
        // `--keep`: the terminal outlives its tab (a background terminal made on purpose).
        let keep = invocation["keep"]?.boolValue == true ? true : nil
        let opensWorkspace = NewTerminalWorkspaceSetting.resolves(
            setting: ctx.services.settings?.snapshot.newTerminalOpensWorkspace ?? NewTerminalWorkspaceSetting.fallback,
            toggled: invocation["toggleWorkspace"]?.boolValue == true
        )
        if invocation.origin == .user, opensWorkspace, !invocation.opensTabInPane, case let windows = ctx.services.windows,
           let windowID = ctx.activeWindow?.state.id {
            let daemon = ctx.services.daemon(for: focused)
            let selected = ctx.services.paneController(for: focused)?.selectedTab
            let start = cwd ?? NewTerminalStart.uninherited(.window, services: ctx.services, daemon: daemon, besides: selected)
                ?? selected?.cwd ?? focused.tabs.first?.cwd
            ctx.registry.track(Task {
                _ = try? await windows.createWorkspace(WorkspaceSpawn(cwd: start, keep: keep == true), on: daemon, into: windowID)
                return nil
            })
            return
        }
        // `layout.newPanePlacement: split`: a new pane like New Pane (Auto Layout) (PanePlacementRouting).
        let pane: PaneModel
        switch PanePlacementRouting.route(ctx, invocation, from: focused, tiles: true) {
        case .tab(let target): pane = target
        case .split(let target, let direction):
            return PaneHandlers.split(ctx, PanePlacementRouting.aimed(invocation, at: target, from: ctx.services.paneController(for: focused)), direction: direction)
        }
        // Ghostty's `tab-inherit-working-directory = false`: the home folder (NewTerminalStart).
        let tabCwd = cwd ?? NewTerminalStart.uninherited(.tab, services: ctx.services, daemon: ctx.services.daemon(for: pane),
                                                          besides: ctx.services.paneController(for: pane)?.selectedTab)
        if let controller = ctx.services.paneController(for: pane) {
            // From the docked agent chat, a tab in the strip (ChatColumnPlacement). Its
            // cwd is the explicit one or nil, for the daemon's resolver (NEW-TERMINAL-INHERITS-CWD).
            var target: PaneController? = controller
            if invocation.origin == .user {
                let spawn = SpawnOptions(cwd: tabCwd, workspace: ctx.services.workspaceKey(of: pane), keep: keep)
                target = ChatColumnPlacement.route(from: controller, respawn: .terminal(spawn), services: ctx.services)
            }
            target?.newTerminalTab(cwd: tabCwd, keep: keep, fromSelectedTab: true, daemonResolvesCwd: target !== controller,
                                   then: NewTabSlot.placing(after: anchor, services: ctx.services, then: nil))
            return
        }
        let handle = pane.handle
        let start = tabCwd ?? pane.tabs.first?.cwd
        let workspace = ctx.services.workspaceKey(of: pane)
        ctx.send("new-tab") { _ = try await $0.newTab(in: handle, options: SpawnOptions(cwd: start, workspace: workspace, keep: keep)) }
    }

    /// `newTab.default` (Cmd-T, the strip's +): a person always gets the New
    /// Tab page, where a terminal, browser or chat is picked; nothing is
    /// opened for them (Leo 2026-10-12). Scripts (CLI, MCP) get a tab of the
    /// kind of the pane's selected tab (`NewTabKind`), through the New
    /// Terminal Tab, New Browser Tab and New Agent Chat paths, so focus and
    /// options match them, and so does `newTab.ofKind` (New <Kind> Tab,
    /// `followsSetting` false).
    /// `inStrip` (New Horizontal Tab) is kept for its callers; Cmd-T itself always adds a tab now.
    static func newTabOfPaneKind(_ ctx: AppActionContext, _ invocation: ActionInvocation, followsSetting: Bool = true,
                                 inStrip: Bool = false, toRight: Bool = false) {
        // A named tab or pane that resolves to nothing is refused by the
        // lookup. Without one, a missing focused pane is not a refusal yet:
        // the active workspace may still be empty (below).
        let named = ctx.namesPane(invocation)
        guard let pane = named ? ctx.daemonPane(invocation) : ctx.services.windows.active?.focusedPane?.pane else {
            guard !named else { return }
            // Cmd-T (and Cmd-I through it) can arrive while the active workspace is still empty (no pane
            // controller): populate it through the shared first-terminal owner (awaiting callers see the pane
            // mount). A person gets the New Tab page, as on a pane (cx-hvc57); a script or remote, a terminal.
            guard invocation.target == nil,
                  let workspace = ctx.scope(invocation).workspace,
                  let key = workspace.key,
                  let daemon = ctx.services.machines.daemon(forWorkspace: workspace.id),
                  let connection = daemon.connection else { ctx.registry.refuse(MiscHandlerStrings.noPane); return }
            let repair = ctx.services.machines.emptyWorkspaceRepair(daemon.machineID, local: ctx.services.emptyWorkspaces)
            guard repair.states[key] == nil else { return }
            let services = ctx.services, page = invocation.origin == .user && followsSetting && services.agentTabs.opensFirstPage(on: daemon)
            ctx.registry.track(Task { @MainActor in
                do {
                    _ = try await repair.fillFirstTab(key) {
                        if page { return try await services.agentTabs.openFirstPage(in: workspace, on: daemon, services: services) }
                        return try await connection.createTerminal(in: key, cwd: daemon.defaultCwd).surface
                    }
                    return nil
                } catch {
                    return ActionWorkFailure("new terminal", mayHaveApplied: true, terminalMayAppear: true)
                }
            })
            return
        }
        let controller = ctx.services.paneController(for: pane)
        // The targeted tab (CLI `--tab`), else the pane's selected tab (an
        // empty pane has none and gets a terminal; never a refusal).
        let selectedID = invocation.target?.kind == .tab ? invocation.target?.id
            : controller?.stripModel.selectedID?.rawValue
            ?? (pane.tabs.indices.contains(pane.defaultTabIndex) ? pane.tabs[pane.defaultTabIndex].id : nil)
        let tab = pane.tabs.first { $0.id == selectedID }
        let user = invocation.origin == .user
        // Agent tabs and pages count as a kind for the user only: a script's
        // `tab new` always gets a terminal or browser it can drive.
        let onAgentTab = user && controller != nil && selectedID.map(ctx.services.agentTabs.isAgentTab) == true
        // Cmd-T opens a tab in the current workspace, like a browser, also in a pane that hides its
        // tab bar (an agent chat alone): Lawrence decided 2026-10-11 (cx-04fy), replacing the
        // "follows the tab bar" rule of cx-xt5k. New Workspace (Cmd-N) opens one in a new workspace.
        var sameKind = NewTabKind.resolve(
            selectedKind: tab?.kind, engine: tab?.browserEngine,
            isLocalBrowser: selectedID?.hasPrefix(LocalBrowserTab.prefix) == true, isAgent: onAgentTab
        )
        if onAgentTab, let selectedID, ctx.services.agentTabs.isNewTabPage(selectedID) { sameKind = .page }
        // Right after `tab` for New Tab to the Right and `tabs.newTabPosition: afterCurrent`, else the end (NewTabSlot).
        let after = NewTabSlot.anchor(after: tab, toRight: toRight, user: user, position: ctx.services.settings?.snapshot.newTabPosition)
        var kind = user && followsSetting ? NewTabKind.page : sameKind
        // Agent tabs and the page live in a shown pane whose daemon holds agent tabs; elsewhere,
        // a terminal. A build without the agent page has no new tab page either.
        if kind == .agent || kind == .page, !(controller.map { ctx.services.agentTabs.canHost(on: $0.daemon) } ?? false) { kind = .terminal }
        switch kind {
        case .terminal:
            newTerminal(ctx, invocation, after: after)
        case .browser(let engine):
            var invocation = invocation
            invocation.arguments["cwd"] = nil
            if let engine { invocation.arguments["engine"] = .string(engine) }
            newBrowser(ctx, invocation, after: after)
        case .agent, .page:
            // The docked agent chat gets no tabs: a New Tab page in the strip (ChatColumnPlacement).
            if user, let controller {
                // Nil: Home's pinned dock alone opened the page in a new column beside it.
                guard let strip = ChatColumnPlacement.route(from: controller, respawn: nil, services: ctx.services) else { return }
                if strip !== controller { return strip.newTabPage() }
            }
            let docks = kind == .agent && controller.map { NewChatPlacement.resolve(from: $0) != .here } ?? false // bound for the chat dock: not moved
            let placed = NewTabSlot.placing(after: docks ? nil : after, services: ctx.services, then: nil as (@MainActor (String) -> Void)?)
            if kind == .page {
                controller?.newTabPage(then: placed)
            } else {
                controller?.newAgentTab(then: placed)
            }
        }
    }

    /// `openBrowser.webkit` and `openBrowser.chromium`: `openBrowser` with a fixed engine.
    static func newBrowser(_ ctx: AppActionContext, _ invocation: ActionInvocation, engine: BrowserEngineTag) {
        var invocation = invocation
        invocation.arguments["engine"] = .string(engine.rawValue)
        newBrowser(ctx, invocation)
    }

    /// Reopens a browser tab's page on the other engine in the same pane,
    /// then closes the original (engines are fixed per tab).
    static func reopen(_ ctx: AppActionContext, _ invocation: ActionInvocation, on engine: BrowserEngineTag) {
        guard let (pane, id) = ctx.tab(invocation) else { return }
        guard let tab = pane.tab(id), tab.kind == .browser else { return ctx.refuse(RefusalStrings.notABrowserTab) }
        let current = BrowserEngineTag(rawValue: tab.browserEngine ?? "") ?? .webkit
        guard current != engine else { return }
        if engine == .webkit, ctx.services.cache.pageRequests.proxiedTabs.isProxied(tab.id) {
            return ctx.refuse(RefusalStrings.proxiedTabStaysInChromium)
        }
        if engine == .cef, let reason = ctx.services.cache.browserTabs.cefUnavailableReason() {
            return ctx.refuse(reason)
        }
        let live = ctx.services.cache.existingBrowser(tab.id)?.tab.state.url
        let url = live ?? tab.url.flatMap(URL.init(string:))
        pane.newBrowserTab(url: url, engine: engine.rawValue)
        pane.close([id])
    }

    /// `openBrowser` (`engine` optional: `browser.defaultEngine` when
    /// absent, see `BrowserEngineResolver`). An explicit Chromium request
    /// never silently becomes WebKit.
    static func newBrowser(_ ctx: AppActionContext, _ invocation: ActionInvocation, after anchor: TabModel? = nil) {
        let plan: BrowserOpenPlan
        switch BrowserOpenPlan.make(url: invocation["url"]?.stringValue, engine: invocation["engine"]?.stringValue,
                                    origin: invocation.origin) {
        case .refuse(let message): return ctx.refuse(message)
        case .open(let opened): plan = opened
        case .browserSettings:
            do { try ctx.services.settingsWindow.show(section: .browser, focus: invocation.allowsViewChange) } catch { ctx.refuse(String(describing: error)) }
            return
        case .passwordsPage:
            do { try ChromiumPageRouter.showPasswords(ctx.services, focus: invocation.allowsViewChange) } catch { ctx.refuse(String(describing: error)) }
            return
        }
        let url = plan.url
        let rawProfile = invocation["profile"]?.stringValue
        guard let profileRequest = AgentBrowserProfile.request(rawProfile) else {
            return ctx.refuse(MiscHandlerStrings.unknownBrowserProfile(rawProfile ?? ""))
        }
        if case .explicit(let id) = profileRequest, !ctx.services.browserProfiles.isKnown(id) {
            return ctx.refuse(MiscHandlerStrings.unknownBrowserProfile(id))
        }
        guard let invoked = ctx.daemonPane(invocation) else { return }
        let engine = plan.engine
        // From the docked agent chat, a tab in the strip (ChatColumnPlacement)
        // that opens what the chat works on, not the strip's selected tab. The
        // chat header's Preview is placed beside the chat as an agent's is.
        let pane: PaneModel
        var context: PaneController?
        var docked = false
        if invocation.origin == .user, !invocation.besideCaller, let chat = ctx.services.paneController(for: invoked) {
            let respawn = chatRespawn(ctx, url: url, engine: engine, profile: profileRequest)
            if let target = ChatColumnPlacement.route(from: chat, respawn: respawn, services: ctx.services) {
                pane = target.pane
                if target !== chat { context = chat }
            } else {
                // A lone chat docked and left the browser in its pane.
                pane = invoked
                docked = true
            }
        } else {
            pane = invoked
        }
        if docked { return }
        // A tab the CLI, MCP or a script opens is an agent's: no saved password fills in it (plans/cmux-next/browser.md).
        let cache: TabContentCache? = ctx.services.cache
        var agentTab: (@MainActor (SurfaceID) -> Void)?
        if [.cli, .mcp, .script].contains(invocation.origin) {
            agentTab = { @MainActor [weak cache] surface in cache?.markAgentDriven(surface: surface) }
        }
        // An agent's tab beside its chat: selected there, focus stays in the chat; with no column
        // there it opens unselected in the chat's pane and moves into a new one (AgentBesidePlacement).
        let beside = invocation.besideCaller ? ctx.services.paneController(for: pane) : nil
        if invocation.besideCaller {
            agentTab = AgentBesidePlacement.placed(invocation, pane: pane, controller: beside, services: ctx.services, then: agentTab)
        }
        let background = invocation.besideCaller && invocation.newColumnBeside
        switch profileRequest {
        case .cascade: break
        case .explicit(let id):
            return openInProfile(ctx, pane: pane, url: url, engine: engine, profile: id, background: background, then: agentTab)
        case .agent:
            let profiles = ctx.services.browserProfiles
            ctx.registry.track(Task { @MainActor in
                do {
                    let id = try await AgentBrowserProfile.ensure(profiles)
                    openInProfile(ctx, pane: pane, url: url, engine: engine, profile: id, background: background, then: agentTab)
                    return nil
                } catch {
                    return "agent-browser-profile: \(error)"
                }
            })
            return
        }
        // `layout.newPanePlacement: split` with `layout.tileBrowsers`: a person's browser opens
        // as a tab in the pane Auto Layout picks, then moves into its own pane (PanePlacementRouting).
        // Only a person's browser tiles, so `agentTab` is nil on that path.
        var opener = pane
        var then: (@MainActor (SurfaceID) -> Void)?
        if case .split(let target, let direction) = PanePlacementRouting.route(
            ctx, invocation, from: pane, tiles: PanePlacementRouting.browsersTile(ctx)
        ) {
            opener = target
            then = { @MainActor surface in PanePlacementRouting.moveToSplit(ctx, surface, of: target, direction: direction) }
        }
        if let beside {
            _ = beside.newBrowserTab(url: url, engine: engine, background: background, then: agentTab)
            return
        }
        // In its slot at once (NewTabSuccession), only once it opens in this pane.
        if then == nil { then = NewTabSlot.placing(after: anchor, services: ctx.services, then: agentTab) }
        if let controller = ctx.services.paneController(for: opener) {
            // No URL given: what the selected tab works on (#16620), the chat's from the chat dock.
            if url == nil { (context ?? controller).newBrowserTabFromSelectedTab(engine: engine, in: controller, then: then) }
            else { controller.newBrowserTab(url: url, engine: engine, then: then) }
            return
        }
        openOffscreen(ctx, pane: pane, url: url, engine: engine, profile: nil, then: agentTab)
    }

    /// The browser tab a lone agent chat leaves in its pane when it docks: a
    /// frontend tab on the resolved engine, else nil (the chat stays).
    private static func chatRespawn(_ ctx: AppActionContext, url: URL?, engine: String?,
                                    profile: AgentBrowserProfile.Request) -> SplitRespawn? {
        guard case let browserTabs = ctx.services.cache.browserTabs, browserTabs.isAvailable(on: ctx.services.daemon),
              browserTabs.refusal(for: url) == nil,
              case .open(let choice) = browserTabs.resolve(requested: engine) else { return nil }
        var profileID: String?
        if case .explicit(let id) = profile { profileID = id }
        return .browser(url: url?.absoluteString ?? ctx.services.newTabAddress(for: choice), engine: choice.engine, profileID: profileID)
    }

    /// A new browser tab in browser profile `profile` (openBrowser's
    /// `profile` argument). Without a URL it opens the new tab page rather
    /// than copying the selected tab, whose page belongs to another profile.
    private static func openInProfile(_ ctx: AppActionContext, pane: PaneModel, url: URL?, engine: String?, profile: String,
                                      background: Bool = false, then agentTab: (@MainActor (SurfaceID) -> Void)?) {
        if let controller = ctx.services.paneController(for: pane) {
            controller.newBrowserTab(url: url, engine: engine, background: background, profile: profile, then: agentTab)
            return
        }
        openOffscreen(ctx, pane: pane, url: url, engine: engine, profile: profile, then: agentTab)
    }

    /// A new browser tab (in `profile`, else the cascade's) in a pane that is not on screen.
    private static func openOffscreen(_ ctx: AppActionContext, pane: PaneModel, url: URL?, engine: String?, profile: String?,
                                      then agentTab: (@MainActor (SurfaceID) -> Void)?) {
        let browserTabs = ctx.services.cache.browserTabs
        if let refusal = browserTabs.refusal(in: pane) ?? browserTabs.refusal(for: url) { return ctx.refuse(refusal) }
        guard browserTabs.isAvailable(in: pane) else {
            return ctx.refuse(RefusalStrings.needsDaemonCapability(DaemonCapabilities.shared.frontendBrowserTabs))
        }
        let choice: BrowserEngineChoice
        switch browserTabs.resolve(requested: engine) {
        case .refuse(let reason): return ctx.refuse(BrowserTabService.message(reason))
        case .open(let resolved): choice = resolved
        }
        let address = url?.absoluteString ?? ctx.services.newTabAddress(for: choice)
        let logger = ctx.services.daemon.logger
        ctx.registry.track(Task {
            do {
                let surface = try await browserTabs.open(choice, in: pane, url: address, profile: profile)
                agentTab?(surface)
                return nil
            } catch {
                logger.error("new-frontend-browser-tab failed: \(String(describing: error), privacy: .public)")
                return "new-frontend-browser-tab: \(error)"
            }
        })
    }

    /// With an explicit tab target the tab may be in any workspace; without
    /// one, the focused pane's selected tab (session-local browser tabs too).
    static func close(_ ctx: AppActionContext, _ invocation: ActionInvocation) {
        guard invocation.target?.kind == .tab || invocation["tab"]?.targetValue != nil else {
            // Cmd-W while the focus a creation asked for is still on its way (Cmd-D, then Cmd-W at
            // once: its pane may have no controller yet, and the old pane still has the focus): the
            // creation it focuses closes, never the old pane's tab (CancelledCreation).
            if let content = ctx.focusedContent, case .tab(let id)? = content.focus.state.expectation?.key, content.daemon.cancelCreation(tab: id) { return ctx.services.keyRouter.creationInputCoordinator.drop(tab: id, in: content.contentView.window) }
            guard let (pane, id) = ctx.tab(invocation) else { return }
            // The user's Cmd-W keeps a pinned tab (Chrome parity, PINNED-ITEMS-END-TO-END P3) unless
            // `tabs.cmdWClosesPinnedTabs` is on; the tab menu, the CLI and MCP name the tab and close it.
            if invocation.origin == .user {
                let closesPinned = ctx.services.settings?.snapshot.cmdWClosesPinnedTabs ?? CmdWClosesPinnedTabsSetting.fallback
                // Several selected tabs close together (Chrome); a selected pinned tab stays, as above.
                if let selected = pane.stripModel.keyboardCloseSelection(id, closesPinned: closesPinned) { return CloseUndoToasts.close(in: pane, selected) }
                switch pane.stripModel.keyboardClose(id, closesPinned: closesPinned) {
                case .close: break
                case .select(let next): return pane.select(next)
                case .keep: return ctx.refuse(RefusalStrings.pinnedTabKept)
                // Cmd-W in the Home Chief pane: nothing to close there, so no notice either.
                case .ignore: return
                }
            }
            // A user's Cmd-W gets an undo toast (REOPEN-CLOSED); automation does not.
            return CloseUndoToasts.close(in: pane, [id])
        }
        guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
        if let controller = ctx.services.paneController(for: pane) {
            return CloseUndoToasts.close(in: controller, ctx.actingTabs(invocation, controller, StripTabID(tab.id)))
        }
        let command = ctx.services.daemon(for: pane).closeCommand(for: tab)
        if tab.kind == .remoteTerminal { ctx.services.remoteTerminals.viewClosed(tab) }
        ctx.send(command.label, command.run)
    }

    /// The explicitly targeted tab when no window shows it (rename and pin
    /// then go straight to the daemon; shown tabs use the strip's path).
    private static func hiddenTab(_ ctx: AppActionContext, _ invocation: ActionInvocation) -> TabModel? {
        guard invocation.target?.kind == .tab || invocation["tab"]?.targetValue != nil,
              let (tab, pane) = ctx.daemonTab(invocation), ctx.services.paneController(for: pane) == nil else { return nil }
        return tab
    }

    /// Renames a hidden targeted tab. Returns false when the tab is shown
    /// (or not targeted) and the caller should take the strip path.
    static func renameHidden(_ ctx: AppActionContext, _ invocation: ActionInvocation, name: String?) -> Bool {
        guard let tab = hiddenTab(ctx, invocation), let name else { return false }
        let surface = tab.surface
        ctx.send("rename-surface") { try await $0.renameTab(surface, to: name) }
        return true
    }
}
