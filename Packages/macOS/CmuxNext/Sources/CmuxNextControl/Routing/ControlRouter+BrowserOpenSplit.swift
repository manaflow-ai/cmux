public import CmuxNextSettings
import Foundation

/// `browser.open_split` (`cmux open <url>`, `cmux open -`, cmux-chat):
/// opens one browser tab through the app's `openBrowser` action, the path
/// `cmux browser open` and `cmux tab create browser` take, so the tab is a
/// frontend browser tab and `created` names it (cx-i2iu).
///
/// Params:
/// - `url` (required): an absolute `http` or `https` URL. It is never put in
///   a reply, an error message or a log line, so a one-time code or token in
///   its query stays with the caller.
/// - `workspace_id`: the workspace whose pane gets the tab (`ws_…`, key or
///   handle). Its pane is the one a window shows focused, else its first
///   screen's default pane. Naming a background workspace never switches the
///   view unless `focus` is true.
/// - `terminal_id`: the caller's terminal (`CMUX_TUI_TERMINAL_ID`): its pane
///   gets the tab when no workspace is named. An unknown terminal (another
///   session's) falls through to the focused pane.
/// - `focus` (default false): true lets the run change the view and then
///   shows the new tab (`tab.focus`), as `action.run focus: true` does.
/// - `transparent_background`: cmux-next browser tabs are always opaque, so
///   `true` is refused (`unsupported`); `false` is accepted.
/// - `idempotency_key`, `origin`: as `action.run`; `after`: the router's read barrier.
///
/// Placement (state-ownership.md 3): the named workspace, else the caller's
/// terminal pane, else the focused pane of the front window, else (the window
/// shows a page such as Home, so it has no focused pane) the default pane of
/// the workspace under that page, and then the window shows the tab, or the
/// person would see nothing. The CLI's `browser open` uses the daemon's
/// current pane for that last case; the app uses its own window's workspace.
///
/// The name is cmux's v1 method (the CLI's `open` verb sends it); cmux-next
/// always opens a tab in a pane, never a new split.
extension ControlRouter {
    static let browserOpenSplit = "browser.open_split"

    func browserOpenSplitMethod() -> ControlMethod {
        .async(Self.browserOpenSplit) { [weak self] call in
            guard let self else { throw Self.stopped }
            return try await BrowserOpenSplitRun(router: self).run(call)
        }.claimingProgress().withLimit { _, _ in BrowserOpenSplitRun.limit }
    }
}

/// One `browser.open_split`: the `openBrowser` run, then the reveal.
struct BrowserOpenSplitRun {
    /// The open waits for the tab's echo, then a reveal may wait for its own.
    static let limit: Duration = .seconds(20)

    let router: ControlRouter

    func run(_ call: ControlCall) async throws -> JSONValue {
        let request = try BrowserOpenSplitRequest(call.params, method: call.method)
        let placement = try BrowserOpenSplitPlacement.resolve(request, in: call.snapshot.topology, method: call.method)
        var params: [String: JSONValue] = [
            "action": "openBrowser",
            "args": ["url": .string(request.url)],
            "wait": true,
            "focus": .bool(request.focus),
        ]
        if let origin = request.origin { params["origin"] = .string(origin) }
        if let tab = placement.targetTab { params["target"] = .string("tab:" + tab) }
        if let key = request.idempotencyKey { params["idempotency_key"] = .string(key) }
        let opened = try await router.runAction(forwarding(call, method: "action.run", params))
        let topology = router.snapshots.current.topology
        let created = opened["created"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard let tabID = created.first(where: { topology.tab(id: $0) != nil }) ?? created.first(where: { $0.hasPrefix("tab_") }) else {
            throw ControlError(code: "operation_failed",
                               message: ControlStrings.format("control.error.createdNoSurface", "%@: the action ran but created no surface", call.method))
        }
        var reply: [String: JSONValue] = [
            "tab_id": .string(tabID),
            "created": .array(created.map(JSONValue.string)),
            "placement": .string(placement.kind.rawValue),
            "replayed": opened["replayed"] ?? false,
            "sequence": opened["sequence"] ?? .null,
        ]
        if let located = topology.tab(id: tabID) {
            reply["pane_id"] = .string(located.pane.id)
            reply["workspace_id"] = .string(located.workspace.publicID)
        }
        guard request.focus || placement.kind == .windowWorkspace else {
            reply["revealed"] = false
            return .object(reply)
        }
        // Best effort: the tab exists either way, so a failed reveal is
        // reported in the reply, never as a failed open.
        var reveal: [String: JSONValue] = ["action": "tab.focus", "target": .string("tab:" + tabID), "focus": true, "wait": true]
        if let origin = request.origin { reveal["origin"] = .string(origin) }
        if let key = request.idempotencyKey { reveal["idempotency_key"] = .string(key + ".reveal") }
        do {
            // Against the snapshot that shows the new tab, or its target would not resolve.
            _ = try await router.runAction(forwarding(call, method: "action.run", reveal, snapshot: router.snapshots.current))
            reply["revealed"] = true
        } catch let error as ControlError {
            reply["revealed"] = false
            reply["reveal_error"] = ["code": .string(error.code), "message": .string(error.message)]
        }
        return .object(reply)
    }

    private func forwarding(_ call: ControlCall, method: String, _ params: [String: JSONValue],
                            snapshot: ControlSnapshot? = nil) -> ControlCall {
        ControlCall(request: ControlRequest(id: call.request.id, method: method, params: params), snapshot: snapshot ?? call.snapshot,
                    connection: call.connection, deadline: call.deadline, progress: call.progress)
    }
}

/// The checked params of one `browser.open_split`.
struct BrowserOpenSplitRequest: Sendable, Equatable {
    /// `after` is the router's read barrier (applied before the body runs);
    /// the CLI sends it with every request.
    static let parameters: Set<String> = ["url", "workspace_id", "terminal_id", "focus", "transparent_background", "idempotency_key",
                                          "origin", "after"]

    var url: String
    var workspaceID: String?
    var terminalID: String?
    var focus: Bool
    var idempotencyKey: String?
    var origin: String?

    init(_ params: [String: JSONValue], method: String) throws {
        // A param this method does not know is refused, never ignored.
        if let unknown = params.keys.sorted().first(where: { !Self.parameters.contains($0) }) {
            throw ControlError.invalidParams(ControlStrings.format("control.error.unknownParam", "%1$@ does not take params.%2$@", method, unknown))
        }
        guard let raw = params["url"], !raw.isNull else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.missingParam", "%1$@ requires params.%2$@", method, "url"))
        }
        guard let url = raw.stringValue else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.mustBeString", "%@ must be a string", "url"))
        }
        guard Self.isWebURL(url) else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.openSplitURLScheme", "%@ opens only absolute http and https URLs", method))
        }
        self.url = url
        workspaceID = try Self.string(params, "workspace_id")
        terminalID = try Self.string(params, "terminal_id")
        focus = try Self.bool(params, "focus") ?? false
        if try Self.bool(params, "transparent_background") == true {
            throw ControlError(code: "unsupported",
                               message: ControlStrings.format("control.error.openSplitTransparent",
                                                              "%@ cannot open a transparent browser tab: cmux-next browser tabs are always opaque (omit transparent_background)",
                                                              method),
                               data: ["param": "transparent_background"])
        }
        idempotencyKey = try ControlRouter.idempotencyKey(params)
        origin = try Self.string(params, "origin")
    }

    /// An absolute `http`/`https` URL with a host and no whitespace.
    static func isWebURL(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0.isNewline }),
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return false }
        return true
    }

    private static func string(_ params: [String: JSONValue], _ name: String) throws -> String? {
        guard let value = params[name], !value.isNull else { return nil }
        guard let text = value.stringValue else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.mustBeString", "%@ must be a string", name))
        }
        return text.isEmpty ? nil : text
    }

    private static func bool(_ params: [String: JSONValue], _ name: String) throws -> Bool? {
        guard let value = params[name], !value.isNull else { return nil }
        guard let flag = value.boolValue else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.boolShape", "%@ must be true or false", name))
        }
        return flag
    }
}

/// Where a `browser.open_split` tab goes: a tab of the target pane
/// (`openBrowser` takes a tab target), or nil for the app's focused pane.
struct BrowserOpenSplitPlacement: Sendable, Equatable {
    enum Kind: String, Sendable {
        /// The workspace `workspace_id` names.
        case workspace
        /// The pane of the caller's terminal.
        case callerTerminal = "caller_terminal"
        /// The focused pane of the front window.
        case focusedPane = "focused_pane"
        /// The window shows a page: the default pane of its workspace, then revealed.
        case windowWorkspace = "window_workspace"
    }

    var kind: Kind
    var targetTab: String?

    static func resolve(_ request: BrowserOpenSplitRequest, in topology: ControlTopology, method: String) throws -> Self {
        if let id = request.workspaceID {
            guard let workspace = topology.workspace(id: id) else {
                throw ControlError(code: "not_found", message: ControlStrings.format("control.error.targetNotFound", "No %1$@ matches %2$@", "workspace", id),
                                   data: ["param": "workspace_id"])
            }
            return Self(kind: .workspace, targetTab: try tab(in: workspace, topology: topology, method: method))
        }
        if let terminal = request.terminalID, let tab = terminalTab(terminal, in: topology) {
            return Self(kind: .callerTerminal, targetTab: tab)
        }
        if topology.focus.paneID != nil { return Self(kind: .focusedPane, targetTab: nil) }
        // A page (Home, History) has no pane: the workspace under it.
        guard let id = topology.focus.workspaceID, let workspace = topology.workspace(id: id) else {
            throw noPane(method)
        }
        return Self(kind: .windowWorkspace, targetTab: try tab(in: workspace, topology: topology, method: method))
    }

    /// The tab of `terminal` (daemon id or public `term_…` id).
    static func terminalTab(_ terminal: String, in topology: ControlTopology) -> String? {
        for workspace in topology.workspaces {
            for pane in workspace.panes {
                if let tab = pane.tabs.first(where: { $0.terminalID == terminal || $0.terminalResourceID == terminal }) { return tab.id }
            }
        }
        return nil
    }

    /// A tab of `workspace`'s pane for a new tab: the pane a window shows
    /// focused there, else the first screen's default pane, else its first
    /// pane with a tab.
    static func tab(in workspace: ControlWorkspaceInfo, topology: ControlTopology, method: String) throws -> String {
        var candidates: [ControlPaneInfo] = []
        for window in topology.windows where window.workspaceID == workspace.id {
            if let id = window.focusedPaneID, let pane = workspace.panes.first(where: { $0.id == id }) { candidates.append(pane) }
        }
        for screen in workspace.screens {
            if let id = screen.defaultPaneID, let pane = screen.panes.first(where: { $0.id == id }) { candidates.append(pane) }
            candidates += screen.panes
        }
        for pane in candidates {
            if let selected = pane.selectedTabID, pane.tabs.contains(where: { $0.id == selected }) { return selected }
            if let first = pane.tabs.first { return first.id }
        }
        throw noPane(method)
    }

    static func noPane(_ method: String) -> ControlError {
        ControlError(code: "unavailable", message: ControlStrings.format("control.error.openSplitNoPane",
                                                                         "%@: no pane can take the tab (open a workspace first)", method),
                     data: ["not_run": true])
    }
}
