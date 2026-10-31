public import CmuxNextSettings
import Foundation

/// `file.open` (`cmux open <file>...`, cx-bmie): opens each file through the
/// app's `file.open` action (the path the palette, the File menu and `cmux
/// file open --path` take), in the pane of the caller's terminal, so a file
/// shows in the file, Markdown or image page that fits it.
///
/// Params:
/// - `paths` (array of absolute paths) or `path` (one): the files, opened in
///   order. The CLI makes a relative path absolute against its own working
///   directory before it sends it.
/// - `where`: `tab` (default) or `editor` (the text editor app), as the action.
/// - `as_text` (default false, `cmux open --as-text`): HTML, SVG or Markdown opens as its source
///   in the code editor (the action's `asText`, u18462).
/// - `workspace_id`, `terminal_id`: placement as `browser.open_split`: the
///   named workspace, else the caller's terminal pane, else the focused pane,
///   else the workspace under a page the window shows.
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
        let placement = try BrowserOpenSplitPlacement.resolve(workspaceID: request.workspaceID, agentSession: nil,
                                                              terminalID: request.terminalID, in: topology, method: call.method)
        // `file.open` takes a pane: the pane of the placement's tab, else the action's own focused pane.
        let paneID = placement.targetTab.flatMap { topology.tab(id: $0)?.pane.id }
        var opened: [JSONValue] = []
        for (index, path) in request.paths.enumerated() {
            var args: [String: JSONValue] = ["path": .string(path)]
            if let place = request.place { args["where"] = .string(place) }
            if request.asText { args["asText"] = true }
            var params: [String: JSONValue] = ["action": "file.open", "args": .object(args), "wait": true, "focus": .bool(request.focus)]
            if let paneID { params["target"] = .string("pane:" + paneID) }
            if let origin = request.origin { params["origin"] = .string(origin) }
            if let key = request.idempotencyKey { params["idempotency_key"] = .string("\(key).\(index)") }
            // The first run claims the call's progress; the rest run against the current snapshot.
            let snapshot = index == 0 ? call.snapshot : router.snapshots.current
            let ran = try await router.runAction(ControlCall(request: ControlRequest(id: call.request.id, method: "action.run", params: params),
                                                             snapshot: snapshot, connection: call.connection,
                                                             deadline: call.deadline, progress: call.progress, engineStartMark: call.engineStartMark))
            opened.append(["path": .string(path), "replayed": ran["replayed"] ?? false])
        }
        var reply: [String: JSONValue] = ["opened": .array(opened), "placement": .string(placement.kind.rawValue)]
        if let paneID { reply["pane_id"] = .string(paneID) }
        return .object(reply)
    }
}

/// The checked params of one `file.open`.
struct FileOpenRequest: Sendable, Equatable {
    static let parameters: Set<String> = ["paths", "path", "where", "as_text", "workspace_id", "terminal_id", "focus",
                                          "idempotency_key", "origin", "after"]

    var paths: [String]
    var place: String?
    /// Open as Text: a page cmux renders opens as its source (`as_text`).
    var asText: Bool
    var workspaceID: String?
    var terminalID: String?
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
