public import Foundation

/// Authority filter for a phone spliced onto the local cmux-tui socket.
///
/// The daemon classes every Unix client as trusted-local (cloud-ios.md R9),
/// so the splice is the only place a phone's authority can be narrowed. The
/// policy is an allowlist: a command the phone may send is listed here, and
/// anything else (including commands added to the daemon later) is refused
/// before it reaches the socket. The phone keeps the ordinary control and
/// terminal authority a WebSocket client has, minus `local-admin`, provider
/// authority, and writes that would change the Mac frontend's own state.
public struct DaemonLanePolicy: Sendable {
    /// Largest request line the phone may send. Matches the daemon's
    /// authenticated WebSocket frame cap.
    public static let maximumLineBytes = 4 * 1024 * 1024

    /// The per-device projection subject (`ios-device:<device id>`). The
    /// phone may read and write only this `personal` projection.
    public let projectionSubject: String

    /// The phone's device id: every `set-client-info` carries it as `device_id`, with
    /// `remote: true`, so a phone is never one of this Mac's own views and never another
    /// phone in the sizing order (`host-size-policy-v1`).
    let deviceID: String

    /// `PhoneAccessGate.allowsStartingSessions`, read per request.
    let allowsStartingSessions: @Sendable () -> Bool

    public init(deviceID: String, allowsStartingSessions: @escaping @Sendable () -> Bool = { true }) {
        projectionSubject = "ios-device:\(deviceID)"
        self.deviceID = deviceID
        self.allowsStartingSessions = allowsStartingSessions
    }

    /// Commands that create a workspace, terminal or tab, refused while the
    /// person turned off starting new workspaces from a phone.
    public static let startsSessions: Set<String> = Set(creationFields.keys)
        .union(["new-browser-tab", "reopen-saved-tab-group", "move-tab-to-new-workspace", "move-tab-group-to-new-workspace"])

    /// URL schemes a phone may open in a browser tab (`new-browser-tab`, `browser-navigate`, a split's
    /// `url`): web pages only, never `file:` or another local scheme.
    static let urlSchemes: Set<String> = ["http", "https"]

    /// Commands a phone may send. Grouped by purpose; every entry is a
    /// protocol-12 command the iOS `CmuxTUIControl` client or a reasonable
    /// phone frontend needs.
    public static let allowedCommands: Set<String> = [
        // Session and discovery (read-only).
        "identify", "ping", "server-stats", "set-client-info", "list-clients", "list-workspaces",
        "list-workspace-groups", "list-tab-groups", "list-saved-tab-groups", "list-notifications",
        "list-personal", "list-agents", "list-terminals", "resolve-terminal", "process-info", "machine-usage",
        "machine-listening-tcp", "ids", "export-layout", "subscribe", "terminal-events", "wait-for",
        // Terminal streams and input.
        "attach-surface", "vt-state", "read-screen", "read-scrollback", "scroll-surface", "send", "send-key",
        "copy", "clear-history", "set-terminal-idle-policy", "get-cell-pixels", "set-cell-pixels",
        // Geometry: per-client leases, released when the phone goes away.
        "set-client-sizing", "resize-surface", "release-surface-size", "resize-attached-view",
        "release-attached-view-size", "detach-attached-view",
        // Shared sizing: the size state, the phone's own activity, and this Mac's sizing
        // policy (`host-size-policy-v1`; the phone sets the Mac-wide preference only).
        "get-size-state", "note-size-activity", "get-host-size-policy", "set-host-size-policy",
        // Per-client focus (never moves the Mac's view).
        "client-focus", "report-focus",
        // Topology: the same authority the Mac frontend grants a signed-in phone today.
        "create-workspace", "new-workspace", "rename-workspace", "close-workspace", "move-workspace",
        "set-workspace-metadata", "create-workspace-group", "update-workspace-group", "delete-workspace-group",
        "move-workspace-group", "move-workspace-to-group", "set-personal-workspace", "create-terminal", "new-tab", "new-screen", "new-pane",
        "new-pane-right", "split", "set-ratio", "set-split-ratio", "set-viewport-pane-width", "undo-layout",
        "pane-neighbor", "focus-direction", "swap-pane", "zoom-pane", "close-surface", "close-pane", "close-screen",
        "close-terminal", "rename-pane", "rename-surface", "rename-screen", "focus-pane", "select-tab",
        "select-screen", "select-workspace", "move-tab", "move-terminal", "set-tab-pinned", "move-tab-to-workspace",
        "move-tab-to-split", "move-tab-to-column", "move-tab-to-new-workspace", "create-tab-group",
        "update-tab-group", "add-tabs-to-tab-group", "remove-tabs-from-tab-group", "move-tab-group",
        "move-tab-group-to-split", "move-tab-group-to-column", "move-tab-group-to-new-workspace",
        "ungroup-tab-group", "close-tab-group", "save-tab-group", "unsave-tab-group", "delete-saved-tab-group",
        "reopen-saved-tab-group", "ack-tab-notifications", "notify",
        // Restart Shell: the dead tab's own shell again on this Mac; the surface only (creationFields).
        "restart-tab",
        // Browser tabs the phone can already drive over SSH (CmuxTUIBrowser).
        "new-browser-tab", "browser-frame-presented", "browser-mouse", "browser-mouse-guarded", "browser-wheel",
        "browser-wheel-guarded", "browser-key", "browser-key-press", "browser-insert-text", "browser-navigate",
        "browser-back", "browser-forward", "browser-reload", "browser-activate",
        // Agent chat tabs: cmux-mobile-host sets this Mac's own agent tab host on
        // them (cmux-next-ios/rust/crates/cmux-mobile-host/src/policy.rs); this lane has
        // no such host, so it refuses them below.
        "new-conversation-tab",
        // Frontend projections: guarded per subject below.
        "get-frontend-projection", "put-frontend-projection",
    ]

    /// Fields a phone may set on `set-personal-workspace` (a workspace's place
    /// in the person's own sidebar): never its group, browser profile, theme or
    /// `remote_localhost`.
    static let personalWorkspaceFields: [String] = ["session_id", "workspace_key", "index"]

    /// `cmux.protocol/2` operations a phone may send, each with the params it
    /// may carry (cmux-next-ios/SECURITY.md "Workspace pins, order and Clear All
    /// Notifications" and "Workspace groups"). Every other resource operation
    /// is refused. Group edits name a personal group (`workspace_group.update`,
    /// `.delete`) or place a workspace (`workspace.place`): cmux-mobile-host confirms
    /// those against the Mac's state, so this lane refuses them
    /// (`needsOwnershipCheck`); a new group (`workspace_group.create`) names
    /// no existing object.
    static let allowedResourceOperations: [String: Set<String>] = [
        "notification.clear": ["machine", "session"],
        "sidebar_layout.get": ["machine", "session"],
        "sidebar_layout.update": ["machine", "session", "op"],
        "workspace_group.create": ["machine", "session", "name", "color", "room"],
        "workspace_group.update": ["machine", "session", "workspace_group", "name", "color", "collapsed"],
        "workspace_group.delete": ["machine", "session", "workspace_group"],
        "workspace.place": ["machine", "session", "workspace", "group"],
    ]

    /// The group colors the Mac's menus offer (`GroupColor`).
    static let groupColors: Set<String> = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]

    /// Envelope members a phone may send (never `origin` or `credential`).
    static let resourceFields: Set<String> = ["protocol", "type", "id", "operation", "params", "idempotency_key"]

    /// Fields a phone may set on commands that start a terminal program.
    /// Deny by default (remote-relay-authorization.md): the phone never
    /// chooses the program (`argv`, `command`), its directory (`cwd`), its
    /// environment (`env`, which alone can run code through `DYLD_*` or
    /// `BASH_ENV`) or a terminal host id; a new terminal runs the user's
    /// login shell, which the phone then drives as a terminal (`send`). A
    /// field the daemon adds later is refused until it is reviewed here.
    /// `run` and `create-surface-with-receipt` are not allowed at all.
    static let creationFields: [String: Set<String>] = {
        let mutation: Set<String> = ["origin", "mutation_id", "expected_generation", "expected_revision",
                                     "expected_terminal_revision"]
        let size: Set<String> = ["cols", "rows"]
        return [
            "new-tab": size.union(["pane"]),
            "new-pane": size.union(["pane"]),
            "new-pane-right": size.union(["pane", "width"]),
            "split": size.union(["pane", "dir"]),
            "new-screen": size.union(["workspace"]),
            "new-workspace": size.union(["name"]),
            "create-workspace": mutation.union(["name", "key"]),
            "create-terminal": mutation.union(size).union(["workspace", "key", "name"]),
            // The tab's recorded launch on this Mac; the phone names only the tab.
            "restart-tab": ["surface"],
            // A saved group of this daemon, reopened into one of its panes: each terminal
            // member starts as the login shell in the record's folder (SECURITY.md
            // "Reopen Saved Tab Group"); the phone names no program, folder or env.
            "reopen-saved-tab-group": ["saved", "pane", "transaction"],
            "delete-saved-tab-group": ["saved"],
        ]
    }()

    /// Outcome for one request line.
    public enum Verdict: Equatable, Sendable {
        /// Send the original line (unchanged bytes, newline appended by the splice).
        case forward
        /// Send this line instead (no newline): the object checked, serialized again.
        case rewrite(Data)
        /// Answer the phone with this v12 error line; never send to the daemon.
        case refuse(Data)
    }

    /// Judges one newline-stripped request line from the phone.
    public func evaluate(_ line: Data) -> Verdict {
        guard line.count <= Self.maximumLineBytes else {
            return .refuse(Self.errorLine(id: nil, code: "too_large", message: "request exceeds 4 MiB"))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return .refuse(Self.errorLine(id: nil, code: "bad_request", message: "request is not a JSON object"))
        }
        if object["protocol"] != nil { return Self.resourceVerdict(object) }
        let id = object["id"]
        guard let command = object["cmd"] as? String else {
            return .refuse(Self.errorLine(id: id, code: "bad_request", message: "missing cmd"))
        }
        guard Self.allowedCommands.contains(command) else {
            return .refuse(Self.errorLine(id: id, code: "forbidden",
                                          message: "\(command) is not available to a phone"))
        }
        // Fields too are an allowlist per command: the reviewed creation fields, else the daemon's
        // schema minus program-choosing fields (`commandFields`, generated). A field added later is refused.
        let allowed = Self.creationFields[command] ?? Self.commandFields[command] ?? []
        let extra = Set(object.keys).subtracting(allowed).subtracting(["id", "cmd"])
        guard extra.isEmpty else {
            return .refuse(Self.errorLine(id: id, code: "forbidden",
                                          message: "\(command) does not take \(extra.sorted().joined(separator: ", ")) from a phone"))
        }
        // A `url` that is not a string is refused too, rather than left to the daemon's typed decode.
        if let value = object["url"], !(value is NSNull),
           !Self.urlSchemes.contains((value as? String).flatMap { URLComponents(string: $0)?.scheme?.lowercased() } ?? "") {
            return .refuse(Self.errorLine(id: id, code: "forbidden", message: "phones open only http and https pages"))
        }
        if Self.startsSessions.contains(command), !allowsStartingSessions() {
            return .refuse(Self.errorLine(id: id, code: "forbidden", message: PhoneAccessGate.startRefusal))
        }
        if command == "reopen-saved-tab-group" || command == "delete-saved-tab-group",
           let why = Self.savedGroupRefusal(object, reopen: command == "reopen-saved-tab-group") {
            return .refuse(Self.errorLine(id: id, code: "forbidden", message: why))
        }
        if command == "set-personal-workspace", let why = Self.personalWorkspaceRefusal(object) {
            return .refuse(Self.errorLine(id: id, code: "forbidden", message: why))
        }
        if Self.needsOwnershipCheck(object) {
            return .refuse(Self.errorLine(id: id, code: "forbidden", message: "set-personal-workspace needs the Mac app's phone link"))
        }
        if command == "get-frontend-projection" || command == "put-frontend-projection" {
            return projectionVerdict(object, id: id, write: command == "put-frontend-projection")
        }
        if command == "new-conversation-tab" {
            return .refuse(Self.errorLine(id: id, code: "unavailable",
                                          message: "this Mac's cmux does not let a phone start agent chats"))
        }
        if command == "set-client-info" {
            var marked = object
            marked["remote"] = true
            marked["device_id"] = deviceID
            guard let data = try? JSONSerialization.data(withJSONObject: marked, options: [.sortedKeys]) else {
                return .refuse(Self.errorLine(id: id, code: "bad_request", message: "request is not a JSON object"))
            }
            return .rewrite(data)
        }
        if command == "resize-attached-view", let identity = object["identity"] {
            // A phone relays no other device: its sub-views name no user and no device, so
            // none can take another device's place in the Mac's sizing order.
            var anonymous = object
            if var fields = identity as? [String: Any] {
                fields["user_id"] = nil
                fields["device_id"] = nil
                anonymous["identity"] = fields
            }
            guard let data = try? JSONSerialization.data(withJSONObject: anonymous, options: [.sortedKeys]) else {
                return .refuse(Self.errorLine(id: id, code: "bad_request", message: "request is not a JSON object"))
            }
            return .rewrite(data)
        }
        return .forward
    }

    private func projectionVerdict(_ object: [String: Any], id: Any?, write: Bool) -> Verdict {
        let scope = object["scope"] as? String
        let subject = object["subject_key"] as? String
        if scope == "personal", subject == projectionSubject { return .forward }
        // Reading a shared projection is harmless; writing one would change
        // every frontend's view, and another subject's personal projection
        // belongs to that frontend.
        if !write, scope != "personal" { return .forward }
        return .refuse(Self.errorLine(id: id, code: "forbidden",
                                      message: "phones may only use the personal projection \(projectionSubject)"))
    }

    /// Why a saved tab group line is refused, or nil: `saved` is a short identifier, a
    /// reopen names its `pane` (a number or a short public id), and `transaction` is
    /// 1-128 printable ASCII characters (cmux-mobile-host `saved_group_refusal`).
    static func savedGroupRefusal(_ object: [String: Any], reopen: Bool) -> String? {
        guard let saved = object["saved"] as? String, shortIdentifier(saved) else {
            return "a saved tab group is named by its id"
        }
        if reopen {
            let pane = object["pane"]
            let ok = (pane as? String).map(shortIdentifier) ?? pane.map(isPlace) ?? false
            if !ok { return "reopen-saved-tab-group needs the pane to reopen it in" }
        }
        if let transaction = object["transaction"] {
            guard let text = transaction as? String, (1...128).contains(text.utf8.count),
                  text.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else {
                return "transaction is 1-128 printable characters"
            }
        }
        return nil
    }

    /// `[A-Za-z0-9._:-]`, 1 to 128 bytes.
    static func shortIdentifier(_ text: String) -> Bool {
        (1...128).contains(text.utf8.count) && text.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D || b == 0x5F || b == 0x2E || b == 0x3A
        }
    }

    /// Why a `set-personal-workspace` line is refused, or nil: a short session id,
    /// a workspace key and a place only.
    static func personalWorkspaceRefusal(_ object: [String: Any]) -> String? {
        if let key = object.keys.sorted().first(where: { !personalWorkspaceFields.contains($0) && $0 != "id" && $0 != "cmd" }) {
            return "set-personal-workspace does not take \(key) from a phone"
        }
        func short(_ key: String) -> Bool {
            guard let text = object.first(where: { $0.key == key })?.value as? String, (1...128).contains(text.utf8.count) else { return false }
            return text.utf8.allSatisfy { b in
                (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D || b == 0x5F || b == 0x2E || b == 0x3A
            }
        }
        guard short("session_id"), short("workspace_key") else {
            return "set-personal-workspace needs a session_id and a workspace_key"
        }
        if let index = object["index"], !Self.isPlace(index) {
            return "set-personal-workspace index is a place in the list"
        }
        return nil
    }

    /// A non-negative integer (as Rust's `is_u64`): never a Bool, a float such as
    /// 3.0, or a number past `Int.max`.
    static func isPlace(_ value: Any) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let type = String(validatingCString: number.objCType), ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type)
        else { return false }
        if ["C", "S", "I", "L", "Q"].contains(type) { return number.uint64Value <= UInt64(clamping: Int.max) }
        return number.int64Value >= 0
    }

    /// Lines cmux-mobile-host sends only after the Mac's own state confirms the phone's
    /// object (`services::owned_check`: a live workspace of this session, a pinned
    /// workspace tile). This lane has no such check, so it refuses them.
    static func needsOwnershipCheck(_ object: [String: Any]) -> Bool {
        if object["cmd"] as? String == "set-personal-workspace" { return true }
        return ["sidebar_layout.update", "workspace_group.update", "workspace_group.delete", "workspace.place"]
            .contains(object["operation"] as? String ?? "")
    }

    /// A `cmux.protocol/2` request: one of `allowedResourceOperations` with only its
    /// params, on the current machine and session, sent on as the checked object.
    static func resourceVerdict(_ object: [String: Any]) -> Verdict {
        let id = object["id"]
        if let why = resourceRefusal(object) { return .refuse(resourceErrorLine(id: id, message: why)) }
        if needsOwnershipCheck(object) {
            return .refuse(resourceErrorLine(id: id, message: "\(object["operation"] as? String ?? "this") needs the Mac app's phone link"))
        }
        guard let line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return .refuse(resourceErrorLine(id: id, message: "request is not a JSON object"))
        }
        return .rewrite(line)
    }

    static func resourceRefusal(_ object: [String: Any]) -> String? {
        if let key = object.keys.sorted().first(where: { !resourceFields.contains($0) }) { return "a phone may not send \(key)" }
        guard object["protocol"] as? String == "cmux.protocol/2", object["type"] as? String == "request", object["id"] is String else {
            return "only cmux.protocol/2 requests"
        }
        let operation = object["operation"] as? String ?? ""
        guard let allowed = allowedResourceOperations[operation] else { return "\(operation) is not available to a phone" }
        guard let params = object["params"] as? [String: Any] else { return "params is not an object" }
        if let key = params.keys.sorted().first(where: { !allowed.contains($0) }) {
            return "\(operation) does not take \(key) from a phone"
        }
        for key in ["machine", "session"] {
            guard let value = params.first(where: { $0.key == key })?.value, value as? String != "current" else { continue }
            return "\(key) must be current"
        }
        if operation != "sidebar_layout.get" {
            let key = object["idempotency_key"] as? String ?? ""
            guard (1...128).contains(key.utf8.count), !key.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                return "\(operation) needs an idempotency_key"
            }
        }
        if operation.hasPrefix("workspace_group.") || operation == "workspace.place", let why = groupRefusal(operation, params) {
            return why
        }
        if operation == "sidebar_layout.update" {
            guard let op = params["op"] as? [String: Any], op.count == 2, op["kind"] as? String == "item.remove",
                  let id = op["id"] as? String, mintedItem(id) else {
                return "a phone may only unpin a workspace from the sidebar"
            }
        }
        return nil
    }

    /// 1 to `max` of `[A-Za-z0-9_.:-]` (the daemon's group, room and workspace id characters).
    static func shortID(_ value: Any?, max: Int) -> Bool {
        guard let text = value as? String, (1...max).contains(text.utf8.count) else { return false }
        return text.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D || b == 0x5F || b == 0x2E || b == 0x3A
        }
    }

    /// Why a workspace group operation's values are refused, or nil (policy.rs
    /// `group_params`): a name of 1-256 characters without control characters,
    /// a palette color, a Bool `collapsed`, short group and room ids, a `ws_` id.
    static func groupRefusal(_ operation: String, _ params: [String: Any]) -> String? {
        if let name = params["name"] {
            guard let text = name as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.unicodeScalars.count <= 256,
                  !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                return "\(operation) name is a short name"
            }
        }
        if let color = params["color"], !(color is String && groupColors.contains(color as? String ?? "")) {
            return "\(operation) color is one of the Mac's group colors"
        }
        if let collapsed = params["collapsed"] {
            guard let number = collapsed as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                return "\(operation) collapsed is true or false"
            }
        }
        switch operation {
        case "workspace_group.create":
            if params["name"] == nil { return "workspace_group.create needs a name" }
            if let room = params["room"], !shortID(room, max: 64) { return "workspace_group.create room is a room id" }
        case "workspace_group.update", "workspace_group.delete":
            guard shortID(params["workspace_group"], max: 64) else { return "\(operation) needs a workspace_group" }
            if operation == "workspace_group.update", !["name", "color", "collapsed"].contains(where: params.keys.contains) {
                return "workspace_group.update needs a name, color or collapsed"
            }
        default:
            guard let workspace = params["workspace"] as? String, workspace.hasPrefix("ws_"), shortID(workspace, max: 128) else {
                return "workspace.place needs a workspace of this Mac"
            }
            guard let group = params["group"], group is NSNull || shortID(group, max: 64) else {
                return "workspace.place takes a group, or null to remove it from one"
            }
        }
        return nil
    }

    /// `itm_` and 16 characters of `a-z2-7` (`LayoutItemID.mint()`), never a built-in item.
    static func mintedItem(_ id: String) -> Bool {
        guard id.hasPrefix("itm_") else { return false }
        let rest = id.utf8.dropFirst(4)
        return rest.count == 16 && rest.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x32 && $0 <= 0x37) }
    }

    /// A v2 failure response line (no trailing newline).
    static func resourceErrorLine(id: Any?, message: String) -> Data {
        let response: [String: Any] = [
            "protocol": "cmux.protocol/2", "type": "response", "id": id ?? NSNull(), "ok": false,
            "error": ["code": "origin.forbidden", "message": message, "details": ["reason": "phone_policy"], "retryable": false],
        ]
        return (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data()
    }

    /// A v12 error response line (no trailing newline).
    static func errorLine(id: Any?, code: String, message: String) -> Data {
        var response: [String: Any] = ["ok": false, "error": message, "error_code": code]
        response["id"] = id ?? NSNull()
        return (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data()
    }
}
