import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - V2 JSON method dispatch
extension TerminalController {
    /// Runs a v2 command line (`{"method","params","id"}`) through the
    /// dispatcher in-process and returns the JSON response. Internal seam so
    /// in-app callers (e.g. custom-sidebar button actions) can drive the same
    /// command surface as the socket without reaching the private dispatcher.
    func runV2CommandLine(_ jsonLine: String) -> String {
        processV2Command(jsonLine)
    }

    func processV2Command(_ jsonLine: String) -> String {
        // v1 access-mode gating applies to v2 as well. We can't know which v2 method maps
        // to which v1 command without parsing, so parse first and then apply allow-list.

        let request: ControlRequest
        switch Self.v2Parser.request(fromLine: jsonLine) {
        case .failure(let parseError):
            return Self.v2Encoder.response(for: parseError)
        case .success(let parsed):
            request = parsed
        }

        let bridged = V2SocketRequest(bridging: request)
        let id: Any? = bridged.id
        let method = bridged.method
        let params = bridged.params

        guard Self.executionPolicy(forV2Method: method) == .mainActor else {
            return v2Error(
                id: id,
                code: "invalid_dispatch",
                message: "\(method) must run on the socket worker"
            )
        }

        return withSocketCommandPolicy(commandKey: method, isV2: true, params: params) {
            if let workspaceParamError = v2UnsupportedWorkspaceAliasError(method: method, params: params) {
                return v2Result(id: id, workspaceParamError)
            }

            v2MainSync { self.v2RefreshKnownRefs() }

            switch method {
        case "system.ping":
            return v2Ok(id: id, result: ["pong": true])
        case "system.capabilities":
            return v2Ok(id: id, result: v2Capabilities())
        case "mobile.host.status":
            return v2Result(id: id, self.v2MobileHostStatus(params: params))
        case "mobile.workspace.list":
            return v2Result(id: id, self.v2MobileWorkspaceList(params: params))
        case "mobile.terminal.create", "terminal.create":
            return v2Result(id: id, self.v2MobileTerminalCreate(params: params))
        case "mobile.terminal.input", "terminal.input":
            return v2Result(id: id, self.v2MobileTerminalInput(params: params))
        case "mobile.terminal.replay", "terminal.replay":
            return v2Result(id: id, self.v2MobileTerminalReplay(params: params))
        case "mobile.terminal.viewport", "terminal.viewport":
            return v2Result(id: id, self.v2MobileTerminalViewport(params: params))
        case "mobile.terminal.scroll", "terminal.scroll":
            return v2Result(id: id, self.v2MobileTerminalScroll(params: params))
        case "mobile.terminal.mouse", "terminal.mouse":
            return v2Result(id: id, self.v2MobileTerminalMouse(params: params))

        case "system.identify":
            return v2Ok(id: id, result: v2Identify(params: params))
        case "system.tree":
            return v2Result(id: id, self.v2SystemTree(params: params))
#if DEBUG
        case "debug.session_snapshot_benchmark":
            return v2Result(id: id, self.v2DebugSessionSnapshotBenchmark(params: params))
        case "debug.session_snapshot_seed_scrollback":
            return v2Result(id: id, self.v2DebugSessionSnapshotSeedScrollback(params: params))
        case "mobile.dev_stack_auth.configure":
            return v2Result(id: id, self.v2MobileDevStackAuthConfigure(params: params))
#endif
        case "auth.login":
            return v2Ok(
                id: id,
                result: [
                    "authenticated": true,
                    "required": socketServer.accessMode.requiresPasswordAuth
                ]
            )

        // Windows
        case "window.list":
            return v2Result(id: id, self.v2WindowList(params: params))
        case "window.current":
            return v2Result(id: id, self.v2WindowCurrent(params: params))
        case "window.focus":
            return v2Result(id: id, self.v2WindowFocus(params: params))
        case "window.create":
            return v2Result(id: id, self.v2WindowCreate(params: params))
        case "window.close":
            return v2Result(id: id, self.v2WindowClose(params: params))

        // Workspaces
        case "workspace.list":
            return v2Result(id: id, self.v2WorkspaceList(params: params))
        case "workspace.create":
            return v2Result(id: id, self.v2WorkspaceCreate(params: params))
        case "workspace.select":
            return v2Result(id: id, self.v2WorkspaceSelect(params: params))
        case "workspace.current":
            return v2Result(id: id, self.v2WorkspaceCurrent(params: params))
        case "workspace.close":
            return v2Result(id: id, self.v2WorkspaceClose(params: params))
        case "workspace.move_to_window":
            return v2Result(id: id, self.v2WorkspaceMoveToWindow(params: params))
        case "workspace.reorder":
            return v2Result(id: id, self.v2WorkspaceReorder(params: params))
        case "workspace.reorder_many":
            return v2Result(id: id, self.v2WorkspaceReorderMany(params: params))
        case "workspace.prompt_submit":
            return v2Result(id: id, self.v2WorkspacePromptSubmit(params: params))
        case "workspace.rename":
            return v2Result(id: id, self.v2WorkspaceRename(params: params))
        case "workspace.group.list":
            return v2Result(id: id, self.v2WorkspaceGroupList(params: params))
        case "workspace.group.create":
            return v2Result(id: id, self.v2WorkspaceGroupCreate(params: params))
        case "workspace.group.ungroup":
            return v2Result(id: id, self.v2WorkspaceGroupUngroup(params: params))
        case "workspace.group.delete":
            return v2Result(id: id, self.v2WorkspaceGroupDelete(params: params))
        case "workspace.group.rename":
            return v2Result(id: id, self.v2WorkspaceGroupRename(params: params))
        case "workspace.group.collapse":
            return v2Result(id: id, self.v2WorkspaceGroupSetCollapsed(params: params, isCollapsed: true))
        case "workspace.group.expand":
            return v2Result(id: id, self.v2WorkspaceGroupSetCollapsed(params: params, isCollapsed: false))
        case "workspace.group.pin":
            return v2Result(id: id, self.v2WorkspaceGroupSetPinned(params: params, isPinned: true))
        case "workspace.group.unpin":
            return v2Result(id: id, self.v2WorkspaceGroupSetPinned(params: params, isPinned: false))
        case "workspace.group.add":
            return v2Result(id: id, self.v2WorkspaceGroupAdd(params: params))
        case "workspace.group.remove":
            return v2Result(id: id, self.v2WorkspaceGroupRemove(params: params))
        case "workspace.group.set_anchor":
            return v2Result(id: id, self.v2WorkspaceGroupSetAnchor(params: params))
        case "workspace.group.new_workspace":
            return v2Result(id: id, self.v2WorkspaceGroupNewWorkspace(params: params))
        case "workspace.group.set_color":
            return v2Result(id: id, self.v2WorkspaceGroupSetColor(params: params))
        case "workspace.group.set_icon":
            return v2Result(id: id, self.v2WorkspaceGroupSetIcon(params: params))
        case "workspace.group.move":
            return v2Result(id: id, self.v2WorkspaceGroupMove(params: params))
        case "workspace.group.focus":
            return v2Result(id: id, self.v2WorkspaceGroupFocus(params: params))
        case "workspace.action":
            return v2Result(id: id, self.v2WorkspaceAction(params: params))
        case "extension.sidebar.snapshot":
            return v2Result(id: id, self.v2ExtensionSidebarSnapshot(params: params))
        case "workspace.next":
            return v2Result(id: id, self.v2WorkspaceNext(params: params))
        case "workspace.previous":
            return v2Result(id: id, self.v2WorkspacePrevious(params: params))
        case "workspace.last":
            return v2Result(id: id, self.v2WorkspaceLast(params: params))
        case "workspace.equalize_splits":
            return v2Result(id: id, self.v2WorkspaceEqualizeSplits(params: params))
        case "workspace.remote.configure":
            return v2Result(id: id, self.v2WorkspaceRemoteConfigure(params: params))
        case "workspace.remote.foreground_auth_ready":
            return v2Result(id: id, self.v2WorkspaceRemoteForegroundAuthReady(params: params))
        case "workspace.remote.reconnect":
            return v2Result(id: id, self.v2WorkspaceRemoteReconnect(params: params))
        case "workspace.remote.disconnect":
            return v2Result(id: id, self.v2WorkspaceRemoteDisconnect(params: params))
        case "workspace.remote.status":
            return v2Result(id: id, self.v2WorkspaceRemoteStatus(params: params))
        case "workspace.remote.pty_attach_end":
            return v2Result(id: id, self.v2WorkspaceRemotePTYAttachEnd(params: params))
        case "workspace.remote.terminal_session_end":
            return v2Result(id: id, self.v2WorkspaceRemoteTerminalSessionEnd(params: params))
        case "session.restore_previous":
            return v2Result(id: id, self.v2SessionRestorePrevious())

        // Settings
        case "settings.open":
            return v2Result(id: id, self.v2SettingsOpen(params: params))

        // Feedback
        case "feedback.open":
            return v2Result(id: id, self.v2FeedbackOpen(params: params))

        // Feed (workstream)
        case "feed.jump":
            return v2Result(id: id, self.v2FeedJump(params: params))
        case "feed.list":
            return v2Result(id: id, self.v2FeedList(params: params))


        // Surfaces / input
        case "surface.list":
            return v2Result(id: id, self.v2SurfaceList(params: params))
        case "surface.current":
            return v2Result(id: id, self.v2SurfaceCurrent(params: params))
        case "surface.focus":
            return v2Result(id: id, self.v2SurfaceFocus(params: params))
        case "surface.split":
            return v2Result(id: id, self.v2SurfaceSplit(params: params))
        case "surface.respawn":
            return v2Result(id: id, self.v2SurfaceRespawn(params: params))
        case "surface.create":
            return v2Result(id: id, self.v2SurfaceCreate(params: params))
        case "surface.close":
            return v2Result(id: id, self.v2SurfaceClose(params: params))
        case "surface.move":
            return v2Result(id: id, self.v2SurfaceMove(params: params))
        case "surface.reorder":
            return v2Result(id: id, self.v2SurfaceReorder(params: params))
        case "surface.action":
            return v2Result(id: id, self.v2TabAction(params: params))
        case "tab.action":
            return v2Result(id: id, self.v2TabAction(params: params))
        case "surface.drag_to_split":
            return v2Result(id: id, self.v2SurfaceDragToSplit(params: params))
        case "surface.split_off":
            return v2Result(id: id, self.v2SurfaceSplitOff(params: params))
        case "surface.refresh":
            return v2Result(id: id, self.v2SurfaceRefresh(params: params))
        case "surface.health":
            return v2Result(id: id, self.v2SurfaceHealth(params: params))
        case "surface.resume.set":
            return v2Result(id: id, self.v2SurfaceResumeSet(params: params))
        case "surface.resume.get":
            return v2Result(id: id, self.v2SurfaceResumeGet(params: params))
        case "surface.resume.clear":
            return v2Result(id: id, self.v2SurfaceResumeClear(params: params))
        case "debug.terminals":
            return v2Result(id: id, self.v2DebugTerminals(params: params))
        case "surface.send_text":
            return v2Result(id: id, self.v2SurfaceSendText(params: params))
        case "surface.send_key":
            return v2Result(id: id, self.v2SurfaceSendKey(params: params))
        case "surface.report_tty":
            return v2Result(id: id, self.v2SurfaceReportTTY(params: params))
        case "surface.report_shell_state":
            return v2Result(id: id, self.v2SurfaceReportShellState(params: params))
        case "surface.ports_kick":
            return v2Result(id: id, self.v2SurfacePortsKick(params: params))
        case "surface.clear_history":
            return v2Result(id: id, self.v2SurfaceClearHistory(params: params))
        case "surface.trigger_flash":
            return v2Result(id: id, self.v2SurfaceTriggerFlash(params: params))

        // Panes
        case "pane.list":
            return v2Result(id: id, self.v2PaneList(params: params))
        case "pane.focus":
            return v2Result(id: id, self.v2PaneFocus(params: params))
        case "pane.surfaces":
            return v2Result(id: id, self.v2PaneSurfaces(params: params))
        case "pane.create":
            return v2Result(id: id, self.v2PaneCreate(params: params))
        case "pane.resize":
            return v2Result(id: id, self.v2PaneResize(params: params))
        case "pane.swap":
            return v2Result(id: id, self.v2PaneSwap(params: params))
        case "pane.break":
            return v2Result(id: id, self.v2PaneBreak(params: params))
        case "pane.join":
            return v2Result(id: id, self.v2PaneJoin(params: params))
        case "pane.last":
            return v2Result(id: id, self.v2PaneLast(params: params))

        // Notifications
        case "notification.create":
            return v2Result(id: id, self.v2NotificationCreate(params: params))
        case "notification.create_for_caller":
            return v2Result(id: id, self.v2NotificationCreateForCaller(params: params))
        case "notification.create_for_surface":
            return v2Result(id: id, self.v2NotificationCreateForSurface(params: params))
        case "notification.create_for_target":
            return v2Result(id: id, self.v2NotificationCreateForTarget(params: params))
        case "notification.list":
            return v2Ok(id: id, result: self.v2NotificationList())
        case "notification.clear":
            return v2Result(id: id, self.v2NotificationClear())
        case "notification.dismiss":
            return v2Result(id: id, self.v2NotificationDismiss(params: params))
        case "notification.mark_read":
            return v2Result(id: id, self.v2NotificationMarkRead(params: params))
        case "notification.open":
            return v2Result(id: id, self.v2NotificationOpen(params: params))
        case "notification.jump_to_unread":
            return v2Result(id: id, self.v2NotificationJumpToUnread())

        // App focus
        case "app.focus_override.set":
            return v2Result(id: id, self.v2AppFocusOverride(params: params))
        case "app.simulate_active":
            return v2Result(id: id, self.v2AppSimulateActive())

        // Browser
        case "browser.open_split":
            return v2Result(id: id, self.v2BrowserOpenSplit(params: params))
        case "browser.navigate":
            return v2Result(id: id, self.v2BrowserNavigate(params: params))
        case "browser.back":
            return v2Result(id: id, self.v2BrowserBack(params: params))
        case "browser.forward":
            return v2Result(id: id, self.v2BrowserForward(params: params))
        case "browser.reload":
            return v2Result(id: id, self.v2BrowserReload(params: params))
        case "browser.url.get":
            return v2Result(id: id, self.v2BrowserGetURL(params: params))
        case "browser.focus_webview":
            return v2Result(id: id, self.v2BrowserFocusWebView(params: params))
        case "browser.is_webview_focused":
            return v2Result(id: id, self.v2BrowserIsWebViewFocused(params: params))
        case "browser.snapshot":
            return v2Result(id: id, self.v2BrowserSnapshot(params: params))
        case "browser.eval":
            return v2Result(id: id, self.v2BrowserEval(params: params))
        case "browser.wait":
            return v2Result(id: id, self.v2BrowserWait(params: params))
        case "browser.click":
            return v2Result(id: id, self.v2BrowserClick(params: params))
        case "browser.dblclick":
            return v2Result(id: id, self.v2BrowserDblClick(params: params))
        case "browser.hover":
            return v2Result(id: id, self.v2BrowserHover(params: params))
        case "browser.focus":
            return v2Result(id: id, self.v2BrowserFocusElement(params: params))
        case "browser.type":
            return v2Result(id: id, self.v2BrowserType(params: params))
        case "browser.fill":
            return v2Result(id: id, self.v2BrowserFill(params: params))
        case "browser.press":
            return v2Result(id: id, self.v2BrowserPress(params: params))
        case "browser.keydown":
            return v2Result(id: id, self.v2BrowserKeyDown(params: params))
        case "browser.keyup":
            return v2Result(id: id, self.v2BrowserKeyUp(params: params))
        case "browser.check":
            return v2Result(id: id, self.v2BrowserCheck(params: params, checked: true))
        case "browser.uncheck":
            return v2Result(id: id, self.v2BrowserCheck(params: params, checked: false))
        case "browser.select":
            return v2Result(id: id, self.v2BrowserSelect(params: params))
        case "browser.scroll":
            return v2Result(id: id, self.v2BrowserScroll(params: params))
        case "browser.scroll_into_view":
            return v2Result(id: id, self.v2BrowserScrollIntoView(params: params))
        case "browser.screenshot":
            return v2Result(id: id, self.v2BrowserScreenshot(params: params))
        case "browser.get.text":
            return v2Result(id: id, self.v2BrowserGetText(params: params))
        case "browser.get.html":
            return v2Result(id: id, self.v2BrowserGetHTML(params: params))
        case "browser.get.value":
            return v2Result(id: id, self.v2BrowserGetValue(params: params))
        case "browser.get.attr":
            return v2Result(id: id, self.v2BrowserGetAttr(params: params))
        case "browser.get.title":
            return v2Result(id: id, self.v2BrowserGetTitle(params: params))
        case "browser.get.count":
            return v2Result(id: id, self.v2BrowserGetCount(params: params))
        case "browser.get.box":
            return v2Result(id: id, self.v2BrowserGetBox(params: params))
        case "browser.get.styles":
            return v2Result(id: id, self.v2BrowserGetStyles(params: params))
        case "browser.is.visible":
            return v2Result(id: id, self.v2BrowserIsVisible(params: params))
        case "browser.is.enabled":
            return v2Result(id: id, self.v2BrowserIsEnabled(params: params))
        case "browser.is.checked":
            return v2Result(id: id, self.v2BrowserIsChecked(params: params))
        case "browser.find.role":
            return v2Result(id: id, self.v2BrowserFindRole(params: params))
        case "browser.find.text":
            return v2Result(id: id, self.v2BrowserFindText(params: params))
        case "browser.find.label":
            return v2Result(id: id, self.v2BrowserFindLabel(params: params))
        case "browser.find.placeholder":
            return v2Result(id: id, self.v2BrowserFindPlaceholder(params: params))
        case "browser.find.alt":
            return v2Result(id: id, self.v2BrowserFindAlt(params: params))
        case "browser.find.title":
            return v2Result(id: id, self.v2BrowserFindTitle(params: params))
        case "browser.find.testid":
            return v2Result(id: id, self.v2BrowserFindTestId(params: params))
        case "browser.find.first":
            return v2Result(id: id, self.v2BrowserFindFirst(params: params))
        case "browser.find.last":
            return v2Result(id: id, self.v2BrowserFindLast(params: params))
        case "browser.find.nth":
            return v2Result(id: id, self.v2BrowserFindNth(params: params))
        case "browser.frame.select":
            return v2Result(id: id, self.v2BrowserFrameSelect(params: params))
        case "browser.frame.main":
            return v2Result(id: id, self.v2BrowserFrameMain(params: params))
        case "browser.dialog.accept":
            return v2Result(id: id, self.v2BrowserDialogRespond(params: params, accept: true))
        case "browser.dialog.dismiss":
            return v2Result(id: id, self.v2BrowserDialogRespond(params: params, accept: false))
        case "browser.import.dialog":
            return v2Result(id: id, self.v2BrowserImportDialog(params: params))
        case "browser.cookies.get":
            return v2Result(id: id, self.v2BrowserCookiesGet(params: params))
        case "browser.cookies.set":
            return v2Result(id: id, self.v2BrowserCookiesSet(params: params))
        case "browser.cookies.clear":
            return v2Result(id: id, self.v2BrowserCookiesClear(params: params))
        case "browser.storage.get":
            return v2Result(id: id, self.v2BrowserStorageGet(params: params))
        case "browser.storage.set":
            return v2Result(id: id, self.v2BrowserStorageSet(params: params))
        case "browser.storage.clear":
            return v2Result(id: id, self.v2BrowserStorageClear(params: params))
        case "browser.tab.new":
            return v2Result(id: id, self.v2BrowserTabNew(params: params))
        case "browser.tab.list":
            return v2Result(id: id, self.v2BrowserTabList(params: params))
        case "browser.tab.switch":
            return v2Result(id: id, self.v2BrowserTabSwitch(params: params))
        case "browser.tab.close":
            return v2Result(id: id, self.v2BrowserTabClose(params: params))
        case "browser.console.list":
            return v2Result(id: id, self.v2BrowserConsoleList(params: params))
        case "browser.console.clear":
            return v2Result(id: id, self.v2BrowserConsoleClear(params: params))
        case "browser.errors.list":
            return v2Result(id: id, self.v2BrowserErrorsList(params: params))
        case "browser.highlight":
            return v2Result(id: id, self.v2BrowserHighlight(params: params))
        case "browser.state.save":
            return v2Result(id: id, self.v2BrowserStateSave(params: params))
        case "browser.state.load":
            return v2Result(id: id, self.v2BrowserStateLoad(params: params))
        case "browser.addinitscript":
            return v2Result(id: id, self.v2BrowserAddInitScript(params: params))
        case "browser.addscript":
            return v2Result(id: id, self.v2BrowserAddScript(params: params))
        case "browser.addstyle":
            return v2Result(id: id, self.v2BrowserAddStyle(params: params))
        case "browser.viewport.set":
            return v2Result(id: id, self.v2BrowserViewportSet(params: params))
        case "browser.geolocation.set":
            return v2Result(id: id, self.v2BrowserGeolocationSet(params: params))
        case "browser.offline.set":
            return v2Result(id: id, self.v2BrowserOfflineSet(params: params))
        case "browser.trace.start":
            return v2Result(id: id, self.v2BrowserTraceStart(params: params))
        case "browser.trace.stop":
            return v2Result(id: id, self.v2BrowserTraceStop(params: params))
        case "browser.network.route":
            return v2Result(id: id, self.v2BrowserNetworkRoute(params: params))
        case "browser.network.unroute":
            return v2Result(id: id, self.v2BrowserNetworkUnroute(params: params))
        case "browser.network.requests":
            return v2Result(id: id, self.v2BrowserNetworkRequests(params: params))
        case "browser.screencast.start":
            return v2Result(id: id, self.v2BrowserScreencastStart(params: params))
        case "browser.screencast.stop":
            return v2Result(id: id, self.v2BrowserScreencastStop(params: params))
        case "browser.input_mouse":
            return v2Result(id: id, self.v2BrowserInputMouse(params: params))
        case "browser.input_keyboard":
            return v2Result(id: id, self.v2BrowserInputKeyboard(params: params))
        case "browser.input_touch":
            return v2Result(id: id, self.v2BrowserInputTouch(params: params))

        // Markdown
        case "markdown.open":
            return v2Result(id: id, self.v2MarkdownOpen(params: params))
        case "file.open":
            return v2Result(id: id, self.v2FileOpen(params: params))

        // Project
        case "project.open":
            return v2Result(id: id, self.v2ProjectOpen(params: params))
        case "project.set_tab":
            return v2Result(id: id, self.v2ProjectSetTab(params: params))
        case "project.set_scheme":
            return v2Result(id: id, self.v2ProjectSetScheme(params: params))
        case "project.set_configuration":
            return v2Result(id: id, self.v2ProjectSetConfiguration(params: params))
        case "project.set_selected_target":
            return v2Result(id: id, self.v2ProjectSetSelectedTarget(params: params))
        case "project.set_selected_file":
            return v2Result(id: id, self.v2ProjectSetSelectedFile(params: params))
        case "project.set_settings_filter":
            return v2Result(id: id, self.v2ProjectSetSettingsFilter(params: params))
        case "project.get_state":
            return v2Result(id: id, self.v2ProjectGetState(params: params))

        case "surface.read_text":
            return v2Result(id: id, self.v2SurfaceReadText(params: params))


#if DEBUG
        // Debug / test-only
        case "debug.shortcut.set":
            return v2Result(id: id, self.v2DebugShortcutSet(params: params))
        case "debug.shortcut.simulate":
            return v2Result(id: id, self.v2DebugShortcutSimulate(params: params))
        case "debug.type":
            return v2Result(id: id, self.v2DebugType(params: params))
        case "debug.textbox.inline_fixture":
            return v2Result(id: id, self.v2DebugTextBoxInlineFixture(params: params))
        case "debug.textbox.interact":
            return v2Result(id: id, self.v2DebugTextBoxInteract(params: params))
        case "debug.app.activate":
            return v2Result(id: id, self.v2DebugActivateApp())
        case "debug.command_palette.toggle":
            return v2Result(id: id, self.v2DebugToggleCommandPalette(params: params))
        case "debug.command_palette.rename_tab.open":
            return v2Result(id: id, self.v2DebugOpenCommandPaletteRenameTabInput(params: params))
        case "debug.command_palette.visible":
            return v2Result(id: id, self.v2DebugCommandPaletteVisible(params: params))
        case "debug.command_palette.selection":
            return v2Result(id: id, self.v2DebugCommandPaletteSelection(params: params))
        case "debug.command_palette.results":
            return v2Result(id: id, self.v2DebugCommandPaletteResults(params: params))
        case "debug.command_palette.rename_input.interact":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputInteraction(params: params))
        case "debug.command_palette.rename_input.delete_backward":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputDeleteBackward(params: params))
        case "debug.command_palette.rename_input.selection":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputSelection(params: params))
        case "debug.command_palette.rename_input.select_all":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputSelectAll(params: params))
        case "debug.browser.address_bar_focused":
            return v2Result(id: id, self.v2DebugBrowserAddressBarFocused(params: params))
        case "debug.browser.favicon":
            return v2Result(id: id, self.v2DebugBrowserFavicon(params: params))
        case "debug.right_sidebar.focus":
            return v2Result(id: id, self.v2DebugRightSidebarFocus(params: params))
        case "debug.sidebar.visible":
            return v2Result(id: id, self.v2DebugSidebarVisible(params: params))
        case "debug.terminal.is_focused":
            return v2Result(id: id, self.v2DebugIsTerminalFocused(params: params))
#if DEBUG
        case "debug.terminal.simulate_file_drop":
            return v2Result(id: id, self.v2DebugSimulateTerminalFileDrop(params: params))
        // debug.sidebar.simulate_drag is dispatched on the socket worker
        // (see ControlCommandExecutionPolicy + the worker switch in processCommand)
        // so its inter-tick Thread.sleep never blocks the main actor.
#endif
        case "debug.terminal.read_text":
            return v2Result(id: id, self.v2DebugReadTerminalText(params: params))
        case "debug.terminal.render_stats":
            return v2Result(id: id, self.v2DebugRenderStats(params: params))
        case "debug.layout":
            return v2Result(id: id, self.v2DebugLayout())
        case "debug.portal.stats":
            return v2Result(id: id, self.v2DebugPortalStats())
        case "debug.bonsplit_underflow.count":
            return v2Result(id: id, self.v2DebugBonsplitUnderflowCount())
        case "debug.bonsplit_underflow.reset":
            return v2Result(id: id, self.v2DebugResetBonsplitUnderflowCount())
        case "debug.empty_panel.count":
            return v2Result(id: id, self.v2DebugEmptyPanelCount())
        case "debug.empty_panel.reset":
            return v2Result(id: id, self.v2DebugResetEmptyPanelCount())
        case "debug.notification.focus":
            return v2Result(id: id, self.v2DebugFocusNotification(params: params))
        case "debug.flash.count":
            return v2Result(id: id, self.v2DebugFlashCount(params: params))
        case "debug.flash.reset":
            return v2Result(id: id, self.v2DebugResetFlashCounts())
        case "debug.panel_snapshot":
            return v2Result(id: id, self.v2DebugPanelSnapshot(params: params))
        case "debug.panel_snapshot.reset":
            return v2Result(id: id, self.v2DebugPanelSnapshotReset(params: params))
        case "debug.window.screenshot":
            return v2Result(id: id, self.v2DebugScreenshot(params: params))
#endif

            default:
                return v2Error(id: id, code: "method_not_found", message: "Unknown method")
            }
        }
    }

}
