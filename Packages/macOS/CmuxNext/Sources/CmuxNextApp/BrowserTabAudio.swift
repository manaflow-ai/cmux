import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextSidebar
import CmuxNextTabs

/// A browser tab's sound in the tab strip and its mute actions (cx-d0d.24,
/// Chrome's tab audio indicator): a speaker while the page plays sound,
/// crossed out while the tab is muted. The page's media script mutes the
/// media of the page and the frames its scripts run in
/// (`BrowserAudioMuting`). Every entrypoint (the speaker in the strip, the
/// speaker on a sidebar row, the tab and workspace menus, the palette, the
/// CLI and MCP) runs one of the actions bound here.
@MainActor
enum BrowserTabAudio {
    /// The toggle the strip's speaker runs (`TabStripIntent.toggleAudioMute`).
    static let toggleActionID: ActionID = "toggleTabAudioMute"
    /// The toggle the sidebar row's speaker runs (`SidebarIntent.toggleWorkspaceAudio`).
    static let workspaceToggleActionID: ActionID = "workspace.toggleAudioMute"

    typealias Page = any BrowserAudioMuting & BrowserTab

    /// What the strip shows for a page in state `state`.
    static func badge(_ state: BrowserTabState?) -> TabAudio? {
        guard let state else { return nil }
        if state.isAudioMuted { return .muted }
        return state.media?.isAudible == true ? .playing : nil
    }

    /// What a sidebar row counts for a page in state `state`.
    static func rowAudio(_ state: BrowserTabState?) -> SidebarWorkspaceAudio? {
        switch badge(state) {
        case .playing?: .playing
        case .muted?: .muted
        case nil: nil
        }
    }

    /// The live page of daemon tab `key` that can mute; nil for a terminal,
    /// an agent chat or a page not loaded.
    static func page(_ key: String, in cache: TabContentCache) -> Page? {
        cache.existingBrowser(key)?.tab as? Page
    }

    /// `toggleTabAudioMute`: mutes the tab's page, or unmutes it.
    static func toggleMute(_ ctx: AppActionContext, _ invocation: ActionInvocation) {
        guard let page = targetPage(ctx, invocation) else { return }
        page.setAudioMuted(!page.state.isAudioMuted)
    }

    /// `tab.muteAudio` (`muted`) and `tab.unmuteAudio`.
    static func setMuted(_ muted: Bool, _ ctx: AppActionContext, _ invocation: ActionInvocation) {
        guard let page = targetPage(ctx, invocation) else { return }
        if page.state.isAudioMuted != muted { page.setAudioMuted(muted) }
    }

    /// `tab.muteOtherAudio`: mutes every other page that plays sound, in
    /// every workspace and window; the target keeps its sound.
    static func muteOthers(_ ctx: AppActionContext, _ invocation: ActionInvocation) {
        guard let (tab, _) = ctx.daemonTab(invocation) else { return }
        for (key, entry) in ctx.services.cache.browsers where key != tab.id {
            guard let page = entry.tab as? Page, badge(page.state) == .playing else { continue }
            page.setAudioMuted(true)
        }
    }

    /// `workspace.toggleAudioMute` (the sidebar row's speaker): mutes the
    /// workspaces' tabs that play sound, or unmutes their muted tabs
    /// (`SidebarWorkspaceAudio.change(for:)`); several selected rows change as one, as Chrome's Mute Tabs.
    static func toggleWorkspaces(_ workspaces: [WorkspaceModel], cache: TabContentCache) throws {
        let pages = pages(of: workspaces, cache: cache)
        guard let shown = SidebarWorkspaceAudio.merge(pages.map { rowAudio($0.state) }) else {
            throw ActionFailure(message: RefusalStrings.workspaceHasNoAudio)
        }
        for page in pages {
            if let muted = shown.change(for: rowAudio(page.state)) { page.setAudioMuted(muted) }
        }
    }

    /// What the workspaces' speakers show together: playing when one plays sound, else muted
    /// when one is muted, else nil (what ``toggleWorkspaces(_:cache:)`` changes).
    static func audio(of workspaces: [WorkspaceModel], cache: TabContentCache) -> SidebarWorkspaceAudio? {
        SidebarWorkspaceAudio.merge(pages(of: workspaces, cache: cache).map { rowAudio($0.state) })
    }

    private static func pages(of workspaces: [WorkspaceModel], cache: TabContentCache) -> [Page] {
        workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).compactMap { page($0.id, in: cache) }
    }

    /// The tab menu's row reads as the change it makes ("Mute Tab" or
    /// "Unmute Tab", Chrome's Mute site / Unmute site), titled from the
    /// direct actions.
    static func targetTitle(_ registry: ActionRegistry, _ cache: TabContentCache, _ invocation: ActionInvocation) -> String? {
        guard let target = invocation.target, target.kind == .tab, let page = page(target.id, in: cache) else { return nil }
        return registry.descriptor(for: page.state.isAudioMuted ? "tab.unmuteAudio" : "tab.muteAudio")?.title
    }

    private static func targetPage(_ ctx: AppActionContext, _ invocation: ActionInvocation) -> Page? {
        guard let (tab, _) = ctx.daemonTab(invocation) else { return nil }
        guard let page = page(tab.id, in: ctx.services.cache) else {
            return ctx.refuse(RefusalStrings.audioMuteNeedsPage)
        }
        return page
    }
}

/// A browser tab's camera and microphone in the tab strip (the other half of Chrome's tab alert indicator), on its sidebar row and in its
/// actions (Chrome's tab recording indicator, which outranks the audio one). The engines
/// report what a page captures (``BrowserTabState/capture``); the strip shows a red camera
/// or microphone, the row shows one too, and a click on the row's shows the tab. Every
/// entrypoint (the row's mark, the tab and workspace menus, the palette, the CLI and MCP)
/// runs one of the actions bound here.
extension BrowserTabAudio {
    /// Shows a tab that captures: the target workspace's, else any window's.
    static let showCapturingActionID: ActionID = "browser.showCapturingTab"
    /// Ends the target tab's capture; the site keeps its permission.
    static let stopCaptureActionID: ActionID = "tab.stopMediaCapture"
    /// Ends the capture and blocks camera and microphone for the tab's site.
    static let blockCaptureActionID: ActionID = "tab.blockMediaCapture"

    typealias CapturePage = any BrowserCaptureControlling & BrowserTab

    /// What the strip shows for a page in state `state`.
    static func captureBadge(_ state: BrowserTabState?) -> TabCapture? {
        state.flatMap { TabCapture(camera: $0.capture.contains(.camera), microphone: $0.capture.contains(.microphone)) }
    }

    /// What a sidebar row merges for a page in state `state`.
    static func rowCapture(_ state: BrowserTabState?) -> SidebarWorkspaceCapture? {
        guard let capture = state?.capture, capture.isCapturing else { return nil }
        return SidebarWorkspaceCapture(camera: capture.contains(.camera), microphone: capture.contains(.microphone))
    }

    /// The tabs that capture now, by daemon tab id, in `workspaces` (every window's when nil),
    /// in tab order; the cache's live pages only (a hibernated page captures nothing).
    static func capturingTabs(in workspaces: [WorkspaceModel], cache: TabContentCache) -> [String] {
        workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id).filter {
            cache.existingBrowser($0)?.tab.state.capture.isCapturing == true
        }
    }

    /// `browser.showCapturingTab`: reveals the first capturing tab of the target workspace,
    /// or of every workspace without one, as a jump from Search Tabs does.
    static func showCapturingTab(_ ctx: AppActionContext, _ invocation: ActionInvocation) -> ActionEffect {
        let workspaces: [WorkspaceModel]
        if invocation.target?.kind == .workspace {
            guard let workspace = try? ctx.workspace(invocation).model else { return .refused(RefusalStrings.noTabCaptures) }
            workspaces = [workspace]
        } else {
            workspaces = ctx.services.machines.allWorkspaces.map(\.0)
        }
        guard let tab = capturingTabs(in: workspaces, cache: ctx.services.cache).first, ctx.services.revealTab(tab) else {
            return .refused(RefusalStrings.noTabCaptures)
        }
        return .done
    }

    /// `tab.stopMediaCapture` (`block` false) and `tab.blockMediaCapture`: the engine ends the
    /// capture and reports it (the marks clear from that report).
    static func stopCapture(block: Bool, _ ctx: AppActionContext, _ invocation: ActionInvocation) -> ActionEffect {
        // `daemonTab` refuses with its own reason (no such tab).
        guard let (tab, _) = ctx.daemonTab(invocation) else { return .done }
        guard let page = ctx.services.cache.existingBrowser(tab.id)?.tab as? CapturePage else {
            return .refused(RefusalStrings.captureNeedsPage)
        }
        guard page.state.capture.isCapturing || block else { return .refused(RefusalStrings.noTabCaptures) }
        if block { page.blockCapture() } else { page.stopCapture() }
        return .done
    }

    /// Binds the three actions (beside `TabHandlers.bindAudio`).
    static func bindCapture(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bindEffect(showCapturingActionID) { showCapturingTab(ctx, $0) }
        registry.bindEffect(stopCaptureActionID) { stopCapture(block: false, ctx, $0) }
        registry.bindEffect(blockCaptureActionID) { stopCapture(block: true, ctx, $0) }
    }
}
