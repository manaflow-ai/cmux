import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// New terminal tab, new browser tab, and close tab for a shown pane (the
/// strip's optimistic path) or any daemon pane, so the CLI can act on a
/// workspace no window shows. Every daemon command is tracked
/// (`ActionRegistry.track`) for callers that await the effect.
enum TabLifecycle {
    static func newTerminal(_ ctx: AppActionContext, _ invocation: ActionInvocation) {
        guard let focused = ctx.daemonPane(invocation) else { return }
        let cwd = invocation["cwd"]?.stringValue
        // `--keep`: the terminal outlives its tab (a background terminal made on purpose).
        let keep = invocation["keep"]?.boolValue == true ? true : nil
        let opensWorkspace = NewTerminalWorkspaceSetting.resolves(
            setting: ctx.services.settings?.snapshot.newTerminalOpensWorkspace ?? NewTerminalWorkspaceSetting.fallback,
            toggled: invocation["toggleWorkspace"]?.boolValue == true
        )
        noteUserChoice(.terminal, ctx, invocation, pane: focused)
        if invocation.origin == .user, opensWorkspace, case let windows = ctx.services.windows,
           let windowID = ctx.activeWindow?.state.id {
            let daemon = ctx.services.daemon(for: focused)
            let start = cwd ?? ctx.services.paneController(for: focused)?.selectedTab?.cwd ?? focused.tabs.first?.cwd
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
        let controller = ctx.services.paneController(for: pane)
        if let controller { return controller.newTerminalTab(cwd: cwd, keep: keep, fromSelectedTab: true) }
        let handle = pane.handle
        let start = cwd ?? pane.tabs.first?.cwd
        let workspace = ctx.services.workspaceKey(of: pane)
        ctx.send("new-tab") { _ = try await $0.newTab(in: handle, options: SpawnOptions(cwd: start, workspace: workspace, keep: keep)) }
    }

    /// `newTab.sameKind` (Cmd-T, the strip's +): a tab of the kind of the
    /// pane's selected tab (`NewTabKind`) unless `tabs.newTabKind` says
    /// otherwise, through the New Terminal Tab, New Browser Tab and New
    /// Agent Chat paths, so focus and options match them. Scripts (CLI,
    /// MCP) always get the same kind, whatever the user's setting.
    static func newTabOfPaneKind(_ ctx: AppActionContext, _ invocation: ActionInvocation) {
        // A named tab or pane that resolves to nothing is refused by the
        // lookup. Without one, a missing focused pane is not a refusal yet:
        // the active workspace may still be empty (below).
        let named = ctx.namesPane(invocation)
        guard let pane = named ? ctx.daemonPane(invocation) : ctx.services.windows.active?.focusedPane?.pane else {
            guard !named else { return }
            // Cmd-T (and Cmd-I through it) can arrive while the active
            // workspace is still empty and has no pane controller. Repair
            // that exact workspace through the shared first-terminal owner;
            // callers awaiting tracked work then observe the pane mount
            // without switching workspaces.
            guard invocation.target == nil,
                  let workspace = ctx.scope(invocation).workspace,
                  let key = workspace.key,
                  let daemon = ctx.services.machines.daemon(forWorkspace: workspace.id),
                  let connection = daemon.connection else { ctx.registry.refuse(MiscHandlerStrings.noPane); return }
            let repair = ctx.services.machines.emptyWorkspaceRepair(daemon.machineID, local: ctx.services.emptyWorkspaces)
            guard repair.states[key] == nil else { return }
            ctx.registry.track(Task { @MainActor in
                do {
                    _ = try await repair.populating(key) {
                        try await connection.createTerminal(in: key, cwd: daemon.defaultCwd).surface
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
        var sameKind = NewTabKind.resolve(
            selectedKind: tab?.kind, engine: tab?.browserEngine,
            isLocalBrowser: selectedID?.hasPrefix(LocalBrowserTab.prefix) == true, isAgent: onAgentTab
        )
        if onAgentTab, let selectedID, ctx.services.agentTabs.isNewTabPage(selectedID) { sameKind = .page }
        let folder = controller?.selectedTab?.cwd ?? tab?.cwd
        var kind = sameKind
        if user {
            let setting = ctx.services.settings?.snapshot.newTabKind ?? NewTabDefaultKind.fallback
            kind = NewTabKind.resolve(setting, sameKind: sameKind, recent: ctx.services.newTabKinds.recent(in: folder))
        }
        // Agent tabs and the page live in a shown pane whose daemon holds agent tabs; elsewhere,
        // a terminal. A build without the agent page has no new tab page either.
        if kind == .agent || kind == .page, !(controller.map { ctx.services.agentTabs.canHost(on: $0.daemon) } ?? false) { kind = .terminal }
        switch kind {
        case .terminal:
            newTerminal(ctx, invocation)
        case .browser(let engine):
            var invocation = invocation
            invocation.arguments["cwd"] = nil
            if let engine { invocation.arguments["engine"] = .string(engine) }
            newBrowser(ctx, invocation)
        case .agent:
            ctx.services.newTabKinds.record(.agent, folder: folder)
            controller?.newAgentTab()
        case .page:
            controller?.newTabPage()
        }
    }

    /// A tab the user opened on purpose, for `tabs.newTabKind: auto`.
    private static func noteUserChoice(_ kind: NewTabKind, _ ctx: AppActionContext, _ invocation: ActionInvocation, pane: PaneModel) {
        guard invocation.origin == .user else { return }
        let folder = ctx.services.paneController(for: pane)?.selectedTab?.cwd ?? pane.tabs.first?.cwd
        ctx.services.newTabKinds.record(kind, folder: folder)
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
    static func newBrowser(_ ctx: AppActionContext, _ invocation: ActionInvocation) {
        let plan: BrowserOpenPlan
        switch BrowserOpenPlan.make(url: invocation["url"]?.stringValue, engine: invocation["engine"]?.stringValue,
                                    origin: invocation.origin) {
        case .refuse(let message): return ctx.refuse(message)
        case .open(let opened): plan = opened
        }
        let url = plan.url
        let rawProfile = invocation["profile"]?.stringValue
        guard let profileRequest = AgentBrowserProfile.request(rawProfile) else {
            return ctx.refuse(MiscHandlerStrings.unknownBrowserProfile(rawProfile ?? ""))
        }
        if case .explicit(let id) = profileRequest, !ctx.services.browserProfiles.isKnown(id) {
            return ctx.refuse(MiscHandlerStrings.unknownBrowserProfile(id))
        }
        guard let pane = ctx.daemonPane(invocation) else { return }
        let engine = plan.engine
        // A refused engine is not remembered, or Auto would repeat the refusal on every Cmd-T in the folder.
        if case .open? = ctx.services.cache.browserTabs.resolve(requested: engine) {
            noteUserChoice(.browser(engine: plan.recordedEngine), ctx, invocation, pane: pane)
        }
        // A tab the CLI, MCP or a script opens is an agent's: no saved password fills in it (plans/cmux-next/browser.md).
        let cache: TabContentCache? = ctx.services.cache
        var agentTab: (@MainActor (SurfaceID) -> Void)?
        if [.cli, .mcp, .script].contains(invocation.origin) {
            agentTab = { @MainActor [weak cache] surface in cache?.markAgentDriven(surface: surface) }
        }
        switch profileRequest {
        case .cascade: break
        case .explicit(let id): return openInProfile(ctx, pane: pane, url: url, engine: engine, profile: id, then: agentTab)
        case .agent:
            let profiles = ctx.services.browserProfiles
            ctx.registry.track(Task { @MainActor in
                do {
                    let id = try await AgentBrowserProfile.ensure(profiles)
                    openInProfile(ctx, pane: pane, url: url, engine: engine, profile: id, then: agentTab)
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
        var then = agentTab
        if case .split(let target, let direction) = PanePlacementRouting.route(
            ctx, invocation, from: pane, tiles: PanePlacementRouting.browsersTile(ctx)
        ) {
            opener = target
            then = { @MainActor surface in PanePlacementRouting.moveToSplit(ctx, surface, of: target, direction: direction) }
        }
        if let controller = ctx.services.paneController(for: opener) {
            // No URL given: what the selected tab works on (#16620).
            if url == nil { controller.newBrowserTabFromSelectedTab(engine: engine, then: then) }
            else { controller.newBrowserTab(url: url, engine: engine, then: then) }
            return
        }
        let browserTabs = ctx.services.cache.browserTabs
        guard browserTabs.isAvailable() else { return ctx.refuse(RefusalStrings.needsDaemonCapability(DaemonCapabilities.shared.frontendBrowserTabs)) }
        let choice: BrowserEngineChoice
        switch browserTabs.resolve(requested: engine) {
        case .refuse(let reason): return ctx.refuse(BrowserTabService.message(reason))
        case .open(let resolved): choice = resolved
        }
        let handle = pane.handle, address = url?.absoluteString ?? ctx.services.newTabAddress(for: choice)
        let logger = ctx.services.daemon.logger
        ctx.registry.track(Task {
            do {
                let surface = try await browserTabs.open(choice, in: handle, url: address)
                agentTab?(surface)
                return nil
            } catch {
                logger.error("new-frontend-browser-tab failed: \(String(describing: error), privacy: .public)")
                return "new-frontend-browser-tab: \(error)"
            }
        })
    }

    /// A new browser tab in browser profile `profile` (openBrowser's
    /// `profile` argument). Without a URL it opens the new tab page rather
    /// than copying the selected tab, whose page belongs to another profile.
    private static func openInProfile(_ ctx: AppActionContext, pane: PaneModel, url: URL?, engine: String?, profile: String,
                                      then agentTab: (@MainActor (SurfaceID) -> Void)?) {
        if let controller = ctx.services.paneController(for: pane) {
            controller.newBrowserTab(url: url, engine: engine, profile: profile, then: agentTab)
            return
        }
        guard case let browserTabs = ctx.services.cache.browserTabs, browserTabs.isAvailable() else {
            return ctx.refuse(RefusalStrings.needsDaemonCapability(DaemonCapabilities.shared.frontendBrowserTabs))
        }
        let choice: BrowserEngineChoice
        switch browserTabs.resolve(requested: engine) {
        case .refuse(let reason): return ctx.refuse(BrowserTabService.message(reason))
        case .open(let resolved): choice = resolved
        }
        let handle = pane.handle, address = url?.absoluteString ?? ctx.services.newTabAddress(for: choice)
        ctx.registry.track(Task {
            do {
                let surface = try await browserTabs.open(choice, in: handle, url: address, profile: profile)
                agentTab?(surface)
                return nil
            } catch {
                return "new-frontend-browser-tab: \(error)"
            }
        })
    }

    /// With an explicit tab target the tab may be in any workspace; without
    /// one, the focused pane's selected tab (session-local browser tabs too).
    static func close(_ ctx: AppActionContext, _ invocation: ActionInvocation) {
        guard invocation.target?.kind == .tab || invocation["tab"]?.targetValue != nil else {
            guard let (pane, id) = ctx.tab(invocation) else { return }
            // The user's Cmd-W keeps a pinned tab (Chrome parity, PINNED-ITEMS-END-TO-END P3) unless
            // `tabs.cmdWClosesPinnedTabs` is on; the tab menu, the CLI and MCP name the tab and close it.
            if invocation.origin == .user {
                let closesPinned = ctx.services.settings?.snapshot.cmdWClosesPinnedTabs ?? CmdWClosesPinnedTabsSetting.fallback
                switch pane.stripModel.keyboardClose(id, closesPinned: closesPinned) {
                case .close: break
                case .select(let next): return pane.select(next)
                case .keep: return ctx.refuse(RefusalStrings.pinnedTabKept)
                }
            }
            // A user's Cmd-W gets an undo toast (REOPEN-CLOSED); automation does not.
            return CloseUndoToasts.close(in: pane, [id])
        }
        guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
        if let controller = ctx.services.paneController(for: pane) {
            return CloseUndoToasts.close(in: controller, [StripTabID(tab.id)])
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
