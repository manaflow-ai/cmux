public import CmuxNextSettings
import Foundation

/// `file.open` (`cmux open <file>...`, cx-bmie): opens each file through the
/// app's `file.open` action (the path the palette, the File menu and `cmux
/// file open --path` take), in the caller's own place, so a file shows in the
/// file, Markdown or image page that fits it.
///
/// Params:
/// - `paths` (array of absolute paths) or `path` (one): the files, opened in
///   order. The CLI makes a relative path absolute against its own working
///   directory before it sends it.
/// - `where`: `tab` (default) or `editor` (the text editor app), as the action.
/// - `as_text` (default false, `cmux open --as-text`): HTML, SVG or Markdown opens as its source
///   in the code editor (the action's `asText`, u18462).
/// - `workspace_id`, `terminal_id`, `caller`: placement as `browser.open_split`
///   (ControlCallerPlacement): the named workspace, else the caller's own place
///   (beside an agent chat or a terminal an agent runs in, the workspace an
///   agent's session runs in when no tab shows its chat, the own pane of a
///   terminal with no agent), else the focused pane, else the workspace under a
///   page the window shows. The reply's `placement` names which (`caller` with
///   `pane_id` for a caller's own place). An agent cmux cannot place is refused
///   (`caller_unavailable`): its file never opens in the focused workspace, Home.
/// - `focus` (default false), `idempotency_key`, `origin`: as `action.run`;
///   each path's run gets the key with `.<index>`. `after`: the read barrier.
///
/// The name is cmux's v1 method, which the CLI's `open` verb sends.
struct FileOpenRun {
    /// Each path waits for its run; a reveal never waits on top.
    static let limit: Duration = .seconds(20)

    static func method(router: ControlRouter) -> ControlMethod {
        .async("file.open") { [weak router] call in
            guard let router else { throw ControlRouter.stopped }
            return try await FileOpenRun(router: router).run(call)
        }.claimingProgress().withLimit { _, _ in limit }
    }

    let router: ControlRouter

    func run(_ call: ControlCall) async throws -> JSONValue {
        let request = try FileOpenRequest(call.params, method: call.method)
        let topology = call.snapshot.topology
        let placement = try BrowserOpenSplitPlacement.resolve(workspaceID: request.workspaceID, caller: request.caller,
                                                              in: topology, method: call.method)
        // `file.open` takes a pane: the pane of the placement's tab; for a caller placed beside itself (an
        // agent: its chat, its terminal, the workspace its session runs in, the Home chat of a Chief turn),
        // the pane `action.run` aims its run at (ControlRouter.placeAtCaller), never the focused pane, Home;
        // else the action's own focused pane.
        let paneID = placement.targetTab.flatMap { topology.tab(id: $0)?.pane.id }
        let caller = placement.kind.isBesideCaller ? request.caller : nil
        // The pane the first file's run was aimed at, for the reply; each file is placed by its own run.
        var placedPane = paneID
        var opened: [JSONValue] = []
        for (index, path) in request.paths.enumerated() {
            var args: [String: JSONValue] = ["path": .string(path)]
            if let place = request.place { args["where"] = .string(place) }
            if request.asText { args["asText"] = true }
            var params: [String: JSONValue] = ["action": "file.open", "args": .object(args), "wait": true, "focus": .bool(request.focus)]
            if let paneID { params["target"] = .string("pane:" + paneID) }
            if let caller { params["caller"] = caller.json }
            if let origin = request.origin { params["origin"] = .string(origin) }
            if let key = request.idempotencyKey { params["idempotency_key"] = .string("\(key).\(index)") }
            // The first run claims the call's progress; the rest run against the current snapshot.
            let snapshot = index == 0 ? call.snapshot : router.snapshots.current
            let ran = try await router.runAction(ControlCall(request: ControlRequest(id: call.request.id, method: "action.run", params: params),
                                                             snapshot: snapshot, connection: call.connection,
                                                             deadline: call.deadline, progress: call.progress, engineStartMark: call.engineStartMark))
            opened.append(["path": .string(path), "replayed": ran["replayed"] ?? false])
            if placedPane == nil, caller != nil, ran["resolved"]?["kind"] == "pane" { placedPane = ran["resolved"]?["id"]?.stringValue }
        }
        // `placement`: `caller` with `pane_id` for a file placed at its caller's own place (the pane its run
        // was aimed at: the caller's helper column, or its own pane, from which the tab moves to a new column
        // right of it); `caller_terminal` with `pane_id` for a terminal no agent runs in; `workspace`,
        // `focused_pane` or `window_workspace` as `browser.open_split`.
        var reply: [String: JSONValue] = ["opened": .array(opened), "placement": .string(placement.kind.fileOpenName)]
        if let placedPane { reply["pane_id"] = .string(placedPane) }
        return .object(reply)
    }
}

/// The checked params of one `file.open`.
struct FileOpenRequest: Sendable, Equatable {
    static let parameters: Set<String> = ["paths", "path", "where", "as_text", "workspace_id", "terminal_id", "caller", "focus",
                                          "idempotency_key", "origin", "after"]

    var paths: [String]
    var place: String?
    /// Open as Text: a page cmux renders opens as its source (`as_text`).
    var asText: Bool
    var workspaceID: String?
    var terminalID: String?
    /// Who asks: `caller`, else the terminal `terminal_id` names.
    var caller: ControlCaller?
    var focus: Bool
    var idempotencyKey: String?
    var origin: String?

    init(_ params: [String: JSONValue], method: String) throws {
        if let unknown = params.keys.sorted().first(where: { !Self.parameters.contains($0) }) {
            throw ControlError.invalidParams(ControlStrings.format("control.error.unknownParam", "%1$@ does not take params.%2$@", method, unknown))
        }
        var paths: [String] = []
        switch params["paths"] {
        case nil, .null: break
        case .array(let items):
            for item in items {
                guard let path = item.stringValue, !path.isEmpty else {
                    throw ControlError.invalidParams(ControlStrings.format("control.error.mustBeString", "%@ must be a string", "paths[]"))
                }
                paths.append(path)
            }
        default:
            throw ControlError.invalidParams(ControlStrings.format("control.error.mustBeString", "%@ must be a string", "paths[]"))
        }
        if let path = try Self.string(params, "path") { paths.append(path) }
        guard !paths.isEmpty else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.missingParam", "%1$@ requires params.%2$@", method, "paths"))
        }
        self.paths = paths
        place = try Self.string(params, "where")
        workspaceID = try Self.string(params, "workspace_id")
        terminalID = try Self.string(params, "terminal_id")
        caller = try ControlCaller(params, terminalID: terminalID)
        focus = try Self.flag(params, "focus")
        asText = try Self.flag(params, "as_text")
        idempotencyKey = try ControlRouter.idempotencyKey(params)
        origin = try Self.string(params, "origin")
    }

    private static func flag(_ params: [String: JSONValue], _ name: String) throws -> Bool {
        guard let value = params[name], !value.isNull else { return false }
        guard let flag = value.boolValue else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.boolShape", "%@ must be true or false", name))
        }
        return flag
    }

    private static func string(_ params: [String: JSONValue], _ name: String) throws -> String? {
        guard let value = params[name], !value.isNull else { return nil }
        guard let text = value.stringValue else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.mustBeString", "%@ must be a string", name))
        }
        return text.isEmpty ? nil : text
    }
}
