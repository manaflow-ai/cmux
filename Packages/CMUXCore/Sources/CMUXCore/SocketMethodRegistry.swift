import Foundation

public enum SocketMethodDomain: String, Sendable {
    case system
    case auth
    case window
    case workspace
    case session
    case settings
    case feedback
    case feed
    case surface
    case tab
    case pane
    case notification
    case app
    case browser
    case markdown
    case debug
    case unknown
}

public enum SocketMethodAvailability: String, Sendable {
    case production
    case debug
}

public struct SocketMethodDescriptor: Equatable, Sendable {
    public let method: SocketMethod
    public let domain: SocketMethodDomain
    public let availability: SocketMethodAvailability
    public let isFocusIntent: Bool

    public init(
        method: SocketMethod,
        domain: SocketMethodDomain,
        availability: SocketMethodAvailability,
        isFocusIntent: Bool
    ) {
        self.method = method
        self.domain = domain
        self.availability = availability
        self.isFocusIntent = isFocusIntent
    }
}

public enum SocketMethodRegistry {
    public static let productionMethodNames: [String] = [
        "system.ping",
        "system.capabilities",
        "system.identify",
        "system.tree",
        "auth.login",
        "auth.status",
        "auth.begin_sign_in",
        "auth.sign_out",
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
        "workspace.rename",
        "workspace.action",
        "workspace.next",
        "workspace.previous",
        "workspace.last",
        "workspace.equalize_splits",
        "workspace.remote.configure",
        "workspace.remote.foreground_auth_ready",
        "workspace.remote.reconnect",
        "workspace.remote.disconnect",
        "workspace.remote.status",
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
        "surface.create",
        "surface.close",
        "surface.drag_to_split",
        "surface.move",
        "surface.reorder",
        "surface.action",
        "tab.action",
        "surface.refresh",
        "surface.health",
        "debug.terminals",
        "surface.send_text",
        "surface.send_key",
        "surface.report_tty",
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
        "notification.create_for_surface",
        "notification.create_for_target",
        "notification.list",
        "notification.clear",
        "app.focus_override.set",
        "app.simulate_active",
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

    public static let debugMethodNames: [String] = [
        "debug.shortcut.set",
        "debug.shortcut.simulate",
        "debug.type",
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
        "debug.window.screenshot",
    ]

    public static let focusIntentMethodNames: Set<String> = [
        SocketMethod.windowFocus.rawValue,
        SocketMethod.workspaceSelect.rawValue,
        SocketMethod.workspaceNext.rawValue,
        SocketMethod.workspacePrevious.rawValue,
        SocketMethod.workspaceLast.rawValue,
        SocketMethod.surfaceFocus.rawValue,
        SocketMethod.paneFocus.rawValue,
        SocketMethod.paneLast.rawValue,
        SocketMethod.browserFocusWebView.rawValue,
        SocketMethod.browserFocus.rawValue,
        SocketMethod.browserTabSwitch.rawValue,
        SocketMethod.debugCommandPaletteToggle.rawValue,
        SocketMethod.debugNotificationFocus.rawValue,
        SocketMethod.debugAppActivate.rawValue,
        SocketMethod.feedJump.rawValue,
    ]

    public static let descriptors: [SocketMethodDescriptor] =
        makeDescriptors(names: productionMethodNames, availability: .production) +
        makeDescriptors(names: debugMethodNames, availability: .debug)

    public static func descriptor(for rawValue: String) -> SocketMethodDescriptor? {
        guard let method = SocketMethod(rawValue: rawValue) else { return nil }
        return descriptor(for: method)
    }

    public static func descriptor(for method: SocketMethod) -> SocketMethodDescriptor? {
        descriptorByName[method.rawValue]
    }

    public static func contains(_ rawValue: String, includeDebug: Bool = true) -> Bool {
        guard let descriptor = descriptor(for: rawValue) else { return false }
        return includeDebug || descriptor.availability == .production
    }

    private static let descriptorByName: [String: SocketMethodDescriptor] =
        Dictionary(uniqueKeysWithValues: descriptors.map { ($0.method.rawValue, $0) })

    private static func makeDescriptors(
        names: [String],
        availability: SocketMethodAvailability
    ) -> [SocketMethodDescriptor] {
        names.map { name in
            SocketMethodDescriptor(
                method: SocketMethod(rawValue: name)!,
                domain: domain(for: name),
                availability: availability,
                isFocusIntent: focusIntentMethodNames.contains(name)
            )
        }
    }

    private static func domain(for rawValue: String) -> SocketMethodDomain {
        let root = rawValue.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""

        switch root {
        case "system": return .system
        case "auth": return .auth
        case "window": return .window
        case "workspace": return .workspace
        case "session": return .session
        case "settings": return .settings
        case "feedback": return .feedback
        case "feed": return .feed
        case "surface": return .surface
        case "tab": return .tab
        case "pane": return .pane
        case "notification": return .notification
        case "app": return .app
        case "browser": return .browser
        case "markdown": return .markdown
        case "debug": return .debug
        default: return .unknown
        }
    }
}
