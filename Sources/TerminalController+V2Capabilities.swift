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


// MARK: - V2 capabilities and identify
extension TerminalController {
    nonisolated func v2Capabilities() -> [String: Any] {
        var methods: [String] = [
            "system.ping",
            "system.capabilities",
            "system.identify",
            "system.tree",
            "system.top",
            "system.memory",
            "mobile.host.status",
            "mobile.attach_ticket.create",
            "mobile.workspace.list",
            "mobile.terminal.create",
            "mobile.terminal.input",
            "mobile.terminal.replay",
            "mobile.terminal.viewport",
            "terminal.create",
            "terminal.input",
            "terminal.replay",
            "terminal.viewport",
            "auth.login",
            "auth.status",
            "auth.begin_sign_in",
            "auth.sign_out",
            "vm.list",
            "vm.create",
            "vm.destroy",
            "vm.exec",
            "vm.attach_info",
            "vm.ssh_info",
            "window.list",
            "window.current",
            "window.focus",
            "window.create",
            "window.close",
            "workspace.list",
            "workspace.create",
            "workspace.select",
            "workspace.current",
            "workspace.close",
            "workspace.move_to_window",
            "workspace.reorder",
            "workspace.reorder_many",
            "workspace.prompt_submit",
            "workspace.rename",
            "workspace.group.list",
            "workspace.group.create",
            "workspace.group.ungroup",
            "workspace.group.delete",
            "workspace.group.rename",
            "workspace.group.collapse",
            "workspace.group.expand",
            "workspace.group.pin",
            "workspace.group.unpin",
            "workspace.group.add",
            "workspace.group.remove",
            "workspace.group.set_anchor",
            "workspace.group.new_workspace",
            "workspace.group.set_color",
            "workspace.group.set_icon",
            "workspace.group.move",
            "workspace.group.focus",
            "workspace.action",
            "extension.sidebar.snapshot",
            "workspace.next",
            "workspace.previous",
            "workspace.last",
            "workspace.equalize_splits",
            "workspace.remote.configure",
            "workspace.remote.foreground_auth_ready",
            "workspace.remote.reconnect",
            "workspace.remote.disconnect",
            "workspace.remote.status",
            "workspace.remote.pty_sessions",
            "workspace.remote.pty_close",
            "workspace.remote.pty_detach",
            "workspace.remote.pty_bridge",
            "workspace.remote.pty_resize",
            "workspace.remote.pty_attach_end",
            "workspace.remote.terminal_session_end",
            "session.restore_previous",
            "settings.open",
            "feedback.open",
            "feedback.submit",
            "feed.push",
            "feed.permission.reply",
            "feed.question.reply",
            "feed.exit_plan.reply",
            "feed.jump",
            "feed.list",
            "surface.list",
            "surface.current",
            "surface.focus",
            "surface.split",
            "surface.respawn",
            "surface.create",
            "surface.close",
            "surface.drag_to_split",
            "surface.split_off",
            "surface.move",
            "surface.reorder",
            "surface.action",
            "tab.action",
            "surface.refresh",
            "surface.health",
            "surface.resume.set",
            "surface.resume.get",
            "surface.resume.clear",
            "debug.terminals",
            "surface.send_text",
            "surface.send_key",
            "surface.report_tty",
            "surface.report_shell_state",
            "surface.ports_kick",
            "surface.read_text",
            "surface.clear_history",
            "surface.trigger_flash",
            "pane.list",
            "pane.focus",
            "pane.surfaces",
            "pane.create",
            "pane.resize",
            "pane.swap",
            "pane.break",
            "pane.join",
            "pane.last",
            "notification.create",
            "notification.create_for_caller",
            "notification.create_for_surface",
            "notification.create_for_target",
            "notification.list",
            "notification.clear",
            "notification.dismiss",
            "notification.mark_read",
            "notification.open",
            "notification.jump_to_unread",
            "app.focus_override.set",
            "app.simulate_active",
            "file.open",
            "markdown.open",
            "browser.open_split",
            "browser.navigate",
            "browser.back",
            "browser.forward",
            "browser.reload",
            "browser.url.get",
            "browser.snapshot",
            "browser.eval",
            "browser.wait",
            "browser.click",
            "browser.dblclick",
            "browser.hover",
            "browser.focus",
            "browser.type",
            "browser.fill",
            "browser.press",
            "browser.keydown",
            "browser.keyup",
            "browser.check",
            "browser.uncheck",
            "browser.select",
            "browser.scroll",
            "browser.scroll_into_view",
            "browser.screenshot",
            "browser.get.text",
            "browser.get.html",
            "browser.get.value",
            "browser.get.attr",
            "browser.get.title",
            "browser.get.count",
            "browser.get.box",
            "browser.get.styles",
            "browser.is.visible",
            "browser.is.enabled",
            "browser.is.checked",
            "browser.focus_webview",
            "browser.is_webview_focused",
            "browser.find.role",
            "browser.find.text",
            "browser.find.label",
            "browser.find.placeholder",
            "browser.find.alt",
            "browser.find.title",
            "browser.find.testid",
            "browser.find.first",
            "browser.find.last",
            "browser.find.nth",
            "browser.frame.select",
            "browser.frame.main",
            "browser.dialog.accept",
            "browser.dialog.dismiss",
            "browser.download.wait",
            "browser.cookies.get",
            "browser.cookies.set",
            "browser.cookies.clear",
            "browser.storage.get",
            "browser.storage.set",
            "browser.storage.clear",
            "browser.tab.new",
            "browser.tab.list",
            "browser.tab.switch",
            "browser.tab.close",
            "browser.console.list",
            "browser.console.clear",
            "browser.errors.list",
            "browser.highlight",
            "browser.state.save",
            "browser.state.load",
            "browser.addinitscript",
            "browser.addscript",
            "browser.addstyle",
            "browser.viewport.set",
            "browser.geolocation.set",
            "browser.offline.set",
            "browser.trace.start",
            "browser.trace.stop",
            "browser.network.route",
            "browser.network.unroute",
            "browser.network.requests",
            "browser.screencast.start",
            "browser.screencast.stop",
            "browser.input_mouse",
            "browser.input_keyboard",
            "browser.input_touch",
        ]
#if DEBUG
        methods.append(contentsOf: [
            "debug.shortcut.set",
            "debug.shortcut.simulate",
            "debug.type",
            "debug.textbox.inline_fixture",
            "debug.textbox.interact",
            "debug.app.activate",
            "debug.command_palette.toggle",
            "debug.command_palette.rename_tab.open",
            "debug.command_palette.visible",
            "debug.command_palette.selection",
            "debug.command_palette.results",
            "debug.command_palette.rename_input.interact",
            "debug.command_palette.rename_input.delete_backward",
            "debug.command_palette.rename_input.selection",
            "debug.command_palette.rename_input.select_all",
            "debug.browser.address_bar_focused",
            "debug.browser.favicon",
            "debug.right_sidebar.focus",
            "debug.sidebar.visible",
            "debug.terminal.is_focused",
            "debug.terminal.read_text",
            "debug.terminal.render_stats",
            "debug.layout",
            "debug.portal.stats",
            "debug.bonsplit_underflow.count",
            "debug.bonsplit_underflow.reset",
            "debug.empty_panel.count",
            "debug.empty_panel.reset",
            "debug.notification.focus",
            "debug.flash.count",
            "debug.flash.reset",
            "debug.panel_snapshot",
            "debug.panel_snapshot.reset",
            "debug.session_snapshot_benchmark",
            "debug.session_snapshot_seed_scrollback",
            "debug.window.screenshot",
            "mobile.dev_stack_auth.configure",
        ])
#endif
#if DEBUG
        methods.append("debug.terminal.simulate_file_drop")
        methods.append("debug.sidebar.simulate_drag")
#endif

        return [
            "protocol": "cmux-socket",
            "version": 2,
            "socket_path": socketServer.currentSocketPath,
            "access_mode": socketServer.accessMode.rawValue,
            "methods": methods.sorted()
        ]
    }

    func v2Identify(params: [String: Any]) -> [String: Any] {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return [
                "socket_path": socketServer.currentSocketPath,
                "focused": NSNull(),
                "caller": NSNull()
            ]
        }

        var focused: [String: Any] = [:]
        v2MainSync {
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            if let wsId = tabManager.selectedTabId,
               let ws = tabManager.tabs.first(where: { $0.id == wsId }) {
                let paneUUID = ws.bonsplitController.focusedPaneId?.id
                let surfaceUUID = ws.focusedPanelId
                focused = [
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": wsId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
                    "pane_id": v2OrNull(paneUUID?.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                    "surface_id": v2OrNull(surfaceUUID?.uuidString),
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceUUID),
                    "tab_id": v2OrNull(surfaceUUID?.uuidString),
                    "tab_ref": v2TabRef(uuid: surfaceUUID),
                    "surface_type": v2OrNull(surfaceUUID.flatMap { ws.panels[$0]?.panelType.rawValue }),
                    "is_browser_surface": v2OrNull(surfaceUUID.flatMap { ws.panels[$0]?.panelType == .browser })
                ]
            } else {
                focused = [
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId)
                ]
            }
        }

        // Optionally validate a caller-provided location (useful for agents calling from inside a surface).
        var resolvedCaller: [String: Any]? = nil
        if let callerObj = params["caller"] as? [String: Any],
           let wsId = v2UUIDAny(callerObj["workspace_id"]) {
            let surfaceId = v2UUIDAny(callerObj["surface_id"]) ?? v2UUIDAny(callerObj["tab_id"])
            v2MainSync {
                let callerTabManager = AppDelegate.shared?.tabManagerFor(tabId: wsId) ?? tabManager
                if let ws = callerTabManager.tabs.first(where: { $0.id == wsId }) {
                    let callerWindowId = v2ResolveWindowId(tabManager: callerTabManager)
                    var payload: [String: Any] = [
                        "window_id": v2OrNull(callerWindowId?.uuidString),
                        "window_ref": v2Ref(kind: .window, uuid: callerWindowId),
                        "workspace_id": wsId.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
                    ]

                    if let surfaceId, ws.panels[surfaceId] != nil {
                        let paneUUID = ws.paneId(forPanelId: surfaceId)?.id
                        payload["surface_id"] = surfaceId.uuidString
                        payload["surface_ref"] = v2Ref(kind: .surface, uuid: surfaceId)
                        payload["tab_id"] = surfaceId.uuidString
                        payload["tab_ref"] = v2TabRef(uuid: surfaceId)
                        payload["surface_type"] = v2OrNull(ws.panels[surfaceId]?.panelType.rawValue)
                        payload["is_browser_surface"] = v2OrNull(ws.panels[surfaceId]?.panelType == .browser)
                        payload["pane_id"] = v2OrNull(paneUUID?.uuidString)
                        payload["pane_ref"] = v2Ref(kind: .pane, uuid: paneUUID)
                    } else {
                        payload["surface_id"] = NSNull()
                        payload["surface_ref"] = NSNull()
                        payload["tab_id"] = NSNull()
                        payload["tab_ref"] = NSNull()
                        payload["surface_type"] = NSNull()
                        payload["is_browser_surface"] = NSNull()
                        payload["pane_id"] = NSNull()
                        payload["pane_ref"] = NSNull()
                    }
                    resolvedCaller = payload
                }
            }
        }

        var result: [String: Any] = [
            "socket_path": socketServer.currentSocketPath,
            "focused": focused.isEmpty ? NSNull() : focused,
            "caller": v2OrNull(resolvedCaller)
        ]
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            result["bundle_identifier"] = bundleIdentifier
        }
        result["app_bundle_path"] = Bundle.main.bundleURL.path
        if let executablePath = Bundle.main.executableURL?.path {
            result["app_executable_path"] = executablePath
        }
        if let cliPath = Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: false)
            .path {
            result["app_cli_path"] = cliPath
        }
        return result
    }

}
