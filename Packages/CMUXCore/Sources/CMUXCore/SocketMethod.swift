import Foundation

public struct SocketMethod: Codable, ExpressibleByStringLiteral, Hashable, RawRepresentable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedValue.isEmpty, trimmedValue == rawValue else {
            return nil
        }

        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        guard let method = SocketMethod(rawValue: value) else {
            preconditionFailure("SocketMethod string literal must not be empty or padded")
        }

        self = method
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        guard let method = SocketMethod(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "SocketMethod must not be empty or padded"
            )
        }

        self = method
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public extension SocketMethod {
    static let systemPing: SocketMethod = "system.ping"
    static let systemCapabilities: SocketMethod = "system.capabilities"
    static let systemIdentify: SocketMethod = "system.identify"
    static let systemTree: SocketMethod = "system.tree"

    static let authStatus: SocketMethod = "auth.status"
    static let authBeginSignIn: SocketMethod = "auth.begin_sign_in"
    static let authSignOut: SocketMethod = "auth.sign_out"

    static let markdownOpen: SocketMethod = "markdown.open"
    static let feedbackOpen: SocketMethod = "feedback.open"
    static let feedbackSubmit: SocketMethod = "feedback.submit"
    static let settingsOpen: SocketMethod = "settings.open"
    static let tabAction: SocketMethod = "tab.action"

    static let windowList: SocketMethod = "window.list"
    static let windowCurrent: SocketMethod = "window.current"
    static let windowFocus: SocketMethod = "window.focus"
    static let windowCreate: SocketMethod = "window.create"
    static let windowClose: SocketMethod = "window.close"

    static let workspaceList: SocketMethod = "workspace.list"
    static let workspaceCreate: SocketMethod = "workspace.create"
    static let workspaceSelect: SocketMethod = "workspace.select"
    static let workspaceCurrent: SocketMethod = "workspace.current"
    static let workspaceClose: SocketMethod = "workspace.close"
    static let workspaceMoveToWindow: SocketMethod = "workspace.move_to_window"
    static let workspaceRename: SocketMethod = "workspace.rename"
    static let workspaceReorder: SocketMethod = "workspace.reorder"
    static let workspaceAction: SocketMethod = "workspace.action"
    static let workspaceNext: SocketMethod = "workspace.next"
    static let workspacePrevious: SocketMethod = "workspace.previous"
    static let workspaceLast: SocketMethod = "workspace.last"
    static let workspaceEqualizeSplits: SocketMethod = "workspace.equalize_splits"
    static let workspaceRemoteConfigure: SocketMethod = "workspace.remote.configure"
    static let workspaceRemoteStatus: SocketMethod = "workspace.remote.status"
    static let workspaceRemoteTerminalSessionEnd: SocketMethod = "workspace.remote.terminal_session_end"

    static let sessionRestorePrevious: SocketMethod = "session.restore_previous"

    static let surfaceList: SocketMethod = "surface.list"
    static let surfaceCurrent: SocketMethod = "surface.current"
    static let surfaceFocus: SocketMethod = "surface.focus"
    static let surfaceSplit: SocketMethod = "surface.split"
    static let surfaceCreate: SocketMethod = "surface.create"
    static let surfaceClose: SocketMethod = "surface.close"
    static let surfaceRefresh: SocketMethod = "surface.refresh"
    static let surfaceHealth: SocketMethod = "surface.health"
    static let surfaceSendText: SocketMethod = "surface.send_text"
    static let surfaceSendKey: SocketMethod = "surface.send_key"
    static let surfaceReadText: SocketMethod = "surface.read_text"
    static let surfaceMove: SocketMethod = "surface.move"
    static let surfaceReorder: SocketMethod = "surface.reorder"
    static let surfaceTriggerFlash: SocketMethod = "surface.trigger_flash"
    static let surfaceClearHistory: SocketMethod = "surface.clear_history"

    static let paneList: SocketMethod = "pane.list"
    static let paneFocus: SocketMethod = "pane.focus"
    static let paneSurfaces: SocketMethod = "pane.surfaces"
    static let paneCreate: SocketMethod = "pane.create"
    static let paneResize: SocketMethod = "pane.resize"
    static let paneSwap: SocketMethod = "pane.swap"
    static let paneBreak: SocketMethod = "pane.break"
    static let paneJoin: SocketMethod = "pane.join"
    static let paneLast: SocketMethod = "pane.last"

    static let browserFocusWebView: SocketMethod = "browser.focus_webview"
    static let browserFocus: SocketMethod = "browser.focus"
    static let browserURLGet: SocketMethod = "browser.url.get"
    static let browserGetTitle: SocketMethod = "browser.get.title"
    static let browserNavigate: SocketMethod = "browser.navigate"
    static let browserOpenSplit: SocketMethod = "browser.open_split"
    static let browserIsWebViewFocused: SocketMethod = "browser.is_webview_focused"
    static let browserSnapshot: SocketMethod = "browser.snapshot"
    static let browserEval: SocketMethod = "browser.eval"
    static let browserWait: SocketMethod = "browser.wait"
    static let browserBack: SocketMethod = "browser.back"
    static let browserForward: SocketMethod = "browser.forward"
    static let browserReload: SocketMethod = "browser.reload"
    static let browserClick: SocketMethod = "browser.click"
    static let browserDblClick: SocketMethod = "browser.dblclick"
    static let browserHover: SocketMethod = "browser.hover"
    static let browserCheck: SocketMethod = "browser.check"
    static let browserUncheck: SocketMethod = "browser.uncheck"
    static let browserScrollIntoView: SocketMethod = "browser.scroll_into_view"
    static let browserType: SocketMethod = "browser.type"
    static let browserFill: SocketMethod = "browser.fill"
    static let browserPress: SocketMethod = "browser.press"
    static let browserKeyDown: SocketMethod = "browser.keydown"
    static let browserKeyUp: SocketMethod = "browser.keyup"
    static let browserSelect: SocketMethod = "browser.select"
    static let browserScroll: SocketMethod = "browser.scroll"
    static let browserGetText: SocketMethod = "browser.get.text"
    static let browserGetHTML: SocketMethod = "browser.get.html"
    static let browserGetValue: SocketMethod = "browser.get.value"
    static let browserGetAttr: SocketMethod = "browser.get.attr"
    static let browserGetCount: SocketMethod = "browser.get.count"
    static let browserGetBox: SocketMethod = "browser.get.box"
    static let browserGetStyles: SocketMethod = "browser.get.styles"
    static let browserIsVisible: SocketMethod = "browser.is.visible"
    static let browserIsEnabled: SocketMethod = "browser.is.enabled"
    static let browserIsChecked: SocketMethod = "browser.is.checked"
    static let browserFindRole: SocketMethod = "browser.find.role"
    static let browserFindNth: SocketMethod = "browser.find.nth"
    static let browserScreenshot: SocketMethod = "browser.screenshot"
    static let browserFrameMain: SocketMethod = "browser.frame.main"
    static let browserFrameSelect: SocketMethod = "browser.frame.select"
    static let browserDialogAccept: SocketMethod = "browser.dialog.accept"
    static let browserDialogDismiss: SocketMethod = "browser.dialog.dismiss"
    static let browserDownloadWait: SocketMethod = "browser.download.wait"
    static let browserCookiesGet: SocketMethod = "browser.cookies.get"
    static let browserCookiesSet: SocketMethod = "browser.cookies.set"
    static let browserCookiesClear: SocketMethod = "browser.cookies.clear"
    static let browserStorageGet: SocketMethod = "browser.storage.get"
    static let browserStorageSet: SocketMethod = "browser.storage.set"
    static let browserStorageClear: SocketMethod = "browser.storage.clear"
    static let browserTabList: SocketMethod = "browser.tab.list"
    static let browserTabNew: SocketMethod = "browser.tab.new"
    static let browserTabSwitch: SocketMethod = "browser.tab.switch"
    static let browserTabClose: SocketMethod = "browser.tab.close"
    static let browserConsoleList: SocketMethod = "browser.console.list"
    static let browserConsoleClear: SocketMethod = "browser.console.clear"
    static let browserStateSave: SocketMethod = "browser.state.save"
    static let browserStateLoad: SocketMethod = "browser.state.load"
    static let browserTraceStart: SocketMethod = "browser.trace.start"
    static let browserTraceStop: SocketMethod = "browser.trace.stop"
    static let browserScreencastStart: SocketMethod = "browser.screencast.start"
    static let browserScreencastStop: SocketMethod = "browser.screencast.stop"
    static let browserInputMouse: SocketMethod = "browser.input_mouse"
    static let browserInputKeyboard: SocketMethod = "browser.input_keyboard"
    static let browserInputTouch: SocketMethod = "browser.input_touch"
    static let browserErrorsList: SocketMethod = "browser.errors.list"
    static let browserHighlight: SocketMethod = "browser.highlight"
    static let browserViewportSet: SocketMethod = "browser.viewport.set"
    static let browserGeolocationSet: SocketMethod = "browser.geolocation.set"
    static let browserOfflineSet: SocketMethod = "browser.offline.set"
    static let browserNetworkRoute: SocketMethod = "browser.network.route"
    static let browserNetworkUnroute: SocketMethod = "browser.network.unroute"
    static let browserNetworkRequests: SocketMethod = "browser.network.requests"

    static let debugCommandPaletteToggle: SocketMethod = "debug.command_palette.toggle"
    static let debugNotificationFocus: SocketMethod = "debug.notification.focus"
    static let debugAppActivate: SocketMethod = "debug.app.activate"
    static let debugTerminals: SocketMethod = "debug.terminals"

    static let feedJump: SocketMethod = "feed.jump"

    static let notificationCreate: SocketMethod = "notification.create"
    static let notificationList: SocketMethod = "notification.list"
    static let notificationClear: SocketMethod = "notification.clear"
}
