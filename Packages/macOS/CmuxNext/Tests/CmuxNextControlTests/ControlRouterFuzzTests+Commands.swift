import CmuxFuzzSupport
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation

/// One line ControlRouterFuzzTests sends and what its reply must carry.
struct RouterFuzzCommand {
    var line: String
    /// The router reads the line as a v2 request: it starts with `{`.
    var isJSON: Bool
    /// The `id` the reply must echo; nil when the line is not one the fuzz built whole.
    var expectedID: JSONValue?
    /// The method the router dispatches; nil when the envelope does not decode.
    var method: String?
    /// The daemon may stall this command's work: its deadline is the control-plane one.
    var mayStall = false
}

/// The commands: `action.run` and `action.batch` built from the registered action catalog (each
/// argument right, wrong-typed or huge, targets live, closed or bogus), every method the router
/// registered with the params its documentation names, unknown methods, v1 lines and mutated lines.
extension ControlRouterFuzzTests {
    /// The params each registered method reads (its doc comment); other methods get general keys.
    static let methodParams: [String: [String]] = [
        "action.list": ["category", "noun", "available_only"],
        "action.describe": ["action", "id", "cli_name", "cli"],
        "tab.focus": ["tab", "id", "focus", "origin", "idempotency_key"],
        "browser.open_split": ["url", "workspace_id", "terminal_id", "caller", "focus", "transparent_background", "idempotency_key", "origin"],
        "file.open": ["paths", "path", "where", "workspace_id", "terminal_id", "focus", "idempotency_key", "origin"],
        "settings.get": ["path", "key"],
        "settings.set": ["path", "key", "value", "confirm", "origin"],
        "settings.reset": ["path", "confirm"],
        "settings.unset": ["path", "confirm"],
        "system.identify": ["caller"],
        "snapshot.get": ["caller"],
        "debug.hangs": ["after", "limit", "clear", "over_budget_after"],
    ]
    static let generalKeys = ["after", "id", "target", "limit", "value", "origin", "caller", "action"]
    static let kinds = ["window", "workspace", "screen", "pane", "tab", "surface", "terminal", "column", "workspace-group", "tab-group", "bogus"]
    static let keys = ["k-a", "k-b", "k-c"]
    static let settingsPaths = ["appearance.density", "ui.animations.enabled", "ui.animationSpeed", "terminal.fontSize", "", ".", "a..b", "__proto__"]
    static let urls = ["https://example.com/a?b=c", "http://localhost:3000/", "file:///etc/hosts", "javascript:alert(1)", "", "example.com"]
    static let v1Lines = ["ping", "PING", "ping extra", "list", "list-windows", "unknown-verb arg", "", "   ", "_cmux_capability_v1 x ping"]
    static let bogusMethods = ["compat.list", "debug.nope", "debug.oracle.settle", "", "  ", "action.run.extra", "ACTION.RUN", "system"]

    static func command(_ rng: inout FuzzRNG, step: Int, catalog: ControlCatalog, methods: [String], daemon: RouterFuzzDaemon) -> RouterFuzzCommand {
        switch rng.below(20) {
        case 0..<9:
            return actionRun(&rng, step: step, catalog: catalog, daemon: daemon)
        case 9, 10:
            return batch(&rng, step: step, catalog: catalog, daemon: daemon)
        case 11..<16:
            let method = rng.element(of: methods) ?? "system.ping"
            return methodCall(&rng, step: step, method: method, catalog: catalog, daemon: daemon)
        case 16:
            let method = rng.oneIn(4) ? FuzzJSON.randomString(&rng) : rng.element(of: bogusMethods) ?? ""
            return methodCall(&rng, step: step, method: method, catalog: catalog, daemon: daemon)
        case 17:
            let line = rng.oneIn(3) ? FuzzJSON.randomString(&rng, limit: 24) : rng.element(of: v1Lines) ?? "ping"
            return raw(framed(line))
        default:
            let base = actionRun(&rng, step: step, catalog: catalog, daemon: daemon).line
            let mutated = FuzzMutator(dictionary: FuzzJSON.tokens).mutate(Data(base.utf8), using: &rng)
            return raw(framed(String(decoding: mutated, as: UTF8.self)))
        }
    }

    // MARK: - Envelopes

    /// `{"id", "method", "params"}`, sometimes with a wrong-typed or missing method or params, and an
    /// id of any JSON type the reply must echo (no fractions: a reply's number need not print alike).
    static func envelope(_ rng: inout FuzzRNG, step: Int, method: String, params: [String: JSONValue], mayStall: Bool = false) -> RouterFuzzCommand {
        var members: [String: JSONValue] = ["method": .string(method), "params": .object(params)]
        var decodes = !method.trimmingCharacters(in: .whitespaces).isEmpty
        var stalls = mayStall
        switch rng.below(24) {
        case 0:
            members["method"] = randomJSON(&rng, notOf: [.string])
            decodes = false
        case 1:
            members["method"] = nil
            decodes = false
        case 2:
            members["params"] = randomJSON(&rng, notOf: [.object])
            stalls = false
        case 3:
            members["method"] = .string("  " + method + " ")
        default:
            break
        }
        let id: JSONValue?
        switch rng.below(8) {
        case 0: id = nil
        case 1: id = .null
        case 2: id = JSONValue(rng.int(in: -1_000...1_000_000))
        case 3: id = .bool(rng.bool())
        case 4: id = .array([.string("a"), ["n": "x"]])
        default: id = .string("f\(step)")
        }
        members["id"] = id
        return RouterFuzzCommand(line: JSONValue.object(members).compactText, isJSON: true, expectedID: decodes ? id ?? .null : .null,
                                 method: decodes ? method.trimmingCharacters(in: .whitespaces) : nil, mayStall: stalls && decodes)
    }

    /// A line the fuzz did not build as an envelope: the reply's id is not known.
    static func raw(_ line: String) -> RouterFuzzCommand {
        RouterFuzzCommand(line: line, isJSON: line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"), expectedID: nil, method: nil)
    }

    /// The transport splits lines at `\n`, so the router never sees one inside a line.
    static func framed(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Actions

    static func actionRun(_ rng: inout FuzzRNG, step: Int, catalog: ControlCatalog, daemon: RouterFuzzDaemon) -> RouterFuzzCommand {
        let action = rng.oneIn(16) ? nil : rng.element(of: catalog.actions)
        let params = actionParams(&rng, action: action, catalog: catalog, daemon: daemon)
        let wait = params["wait"]?.boolValue
        let stalls = action.map { ActionRunLimit.limit(for: $0, wait: wait) == nil && !$0.startsTerminal } ?? false
        return envelope(&rng, step: step, method: "action.run", params: params, mayStall: stalls)
    }

    static func batch(_ rng: inout FuzzRNG, step: Int, catalog: ControlCatalog, daemon: RouterFuzzDaemon) -> RouterFuzzCommand {
        // Past the 64-op limit now and then: `batch_too_large`, or consecutive items when not atomic.
        let count = rng.oneIn(16) ? rng.int(in: 60...70) : rng.below(6)
        var ops: [JSONValue] = []
        for _ in 0..<count {
            let action = rng.oneIn(12) ? nil : rng.element(of: catalog.actions)
            let op = actionParams(&rng, action: action, catalog: catalog, daemon: daemon)
            ops.append(rng.oneIn(24) ? randomJSON(&rng) : .object(op))
        }
        var params: [String: JSONValue] = ["ops": rng.oneIn(16) ? randomJSON(&rng) : .array(ops)]
        if rng.oneIn(4) { params["atomic"] = rng.oneIn(6) ? randomJSON(&rng) : .bool(rng.bool()) }
        if rng.oneIn(4) { params["wait"] = .bool(rng.bool()) }
        if rng.oneIn(4) { params["idempotency_key"] = key(&rng) }
        if rng.oneIn(10) { params["after"] = after(&rng, daemon: daemon) }
        return envelope(&rng, step: step, method: "action.batch", params: params)
    }

    /// `action.run` params for `action` (an unknown action when nil): its name in one of the forms
    /// the router takes, a target, arguments from its schema, and the run-wide keys.
    static func actionParams(_ rng: inout FuzzRNG, action: ControlActionInfo?, catalog: ControlCatalog, daemon: RouterFuzzDaemon) -> [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        if let action {
            switch rng.below(8) {
            case 0:
                params["action"] = .string(action.cliName)
                params["cli"] = true
            case 1: params["cli_name"] = .string(action.cliName)
            case 2: params["id"] = .string(action.id)
            default: params["action"] = .string(action.id)
            }
            let targeted = action.targets.isEmpty ? rng.oneIn(8) : !rng.oneIn(3)
            if targeted { params["target"] = target(&rng, kinds: action.targets, daemon: daemon) }
            var args: [String: JSONValue] = [:]
            for argument in action.arguments where rng.below(8) < (argument.isRequired ? 7 : 4) {
                args[argument.name] = value(&rng, for: argument, daemon: daemon)
            }
            if action.isDestructive, rng.bool() { args["confirm"] = .bool(true) }
            if rng.oneIn(10) {
                let name = "x" + FuzzJSON.randomString(&rng, limit: 6)
                args[name] = randomJSON(&rng)
            }
            if !args.isEmpty || rng.oneIn(4) {
                let key = rng.oneIn(8) ? "arguments" : "args"
                params[key] = rng.oneIn(24) ? randomJSON(&rng, notOf: [.object, .null]) : .object(args)
            }
        } else {
            switch rng.below(5) {
            case 0: params["action"] = .string(FuzzJSON.randomString(&rng))
            case 1: params["action"] = .string(rng.element(of: catalog.aliases.keys.sorted()) ?? "tab.group.new")
            case 2: params["action"] = .string(huge(&rng))
            case 3: params["action"] = randomJSON(&rng, notOf: [.string])
            default: break
            }
        }
        if rng.oneIn(4) { params["wait"] = rng.oneIn(6) ? randomJSON(&rng) : .bool(rng.bool()) }
        if rng.oneIn(4) { params["idempotency_key"] = key(&rng) }
        if rng.oneIn(8) { params["focus"] = flag(&rng) }
        if rng.oneIn(10) { params["background"] = flag(&rng) }
        if rng.oneIn(8) { params["origin"] = origin(&rng) }
        if rng.oneIn(10) { params["after"] = after(&rng, daemon: daemon) }
        if rng.oneIn(12) { params["caller"] = caller(&rng, daemon: daemon) }
        if rng.oneIn(16) { params["interactive"] = true }
        if rng.oneIn(10) {
            let name = "x" + FuzzJSON.randomString(&rng, limit: 6)
            params[name] = randomJSON(&rng)
        }
        return params
    }

    /// A value for `argument`: of its kind and in its range or choices mostly, else wrong-typed,
    /// out of range, an edge number or a huge string.
    static func value(_ rng: inout FuzzRNG, for argument: ControlArgumentInfo, daemon: RouterFuzzDaemon) -> JSONValue {
        if rng.oneIn(6) { return randomJSON(&rng) }
        if rng.oneIn(32) { return .string(huge(&rng)) }
        switch argument.kind {
        case .string:
            return .string(FuzzJSON.randomString(&rng))
        case .int:
            if let range = argument.range, !rng.oneIn(4) { return JSONValue(rng.int(in: range)) }
            return edgeNumber(&rng)
        case .bool:
            return rng.oneIn(3) ? .string(rng.element(of: ["yes", "OFF", "1", "0", "maybe"]) ?? "yes") : .bool(rng.bool())
        case .enumeration:
            let choice = rng.element(of: argument.choices)?.value ?? "none"
            switch rng.below(6) {
            case 0: return .string(choice.uppercased())
            case 1: return .string(" " + choice + " ")
            case 2: return .string(FuzzJSON.randomString(&rng))
            default: return .string(choice)
            }
        case .target:
            return target(&rng, kinds: argument.targetKind.map { [$0] } ?? [], daemon: daemon)
        }
    }

    /// A target naming a live object mostly, else one the daemon closed, a bogus or huge id, an empty
    /// id or a wrong type; written `kind:id`, as `{kind, id}` or bare.
    static func target(_ rng: inout FuzzRNG, kinds: [String], daemon: RouterFuzzDaemon) -> JSONValue {
        let object = self.object(&rng, daemon: daemon)
        let kind = rng.oneIn(3) ? rng.element(of: kinds) ?? object.kind : object.kind
        switch rng.below(10) {
        case 0: return .string(object.id)
        case 1: return .object(["kind": .string(kind), "id": .string(object.id)])
        case 2: return randomJSON(&rng)
        case 3: return .string(kind + ":")
        default: return .string(kind + ":" + object.id)
        }
    }

    static func object(_ rng: inout FuzzRNG, daemon: RouterFuzzDaemon) -> RouterFuzzObject {
        let pick = rng.below(20)
        if pick < 12, let live = rng.element(of: daemon.live) { return live }
        if pick < 17, let closed = rng.element(of: daemon.closed) { return closed }
        if pick < 19 { return RouterFuzzObject(kind: rng.element(of: kinds) ?? "tab", id: FuzzJSON.randomString(&rng)) }
        return RouterFuzzObject(kind: "tab", id: huge(&rng))
    }

    // MARK: - Registered methods

    static func methodCall(_ rng: inout FuzzRNG, step: Int, method: String, catalog: ControlCatalog, daemon: RouterFuzzDaemon) -> RouterFuzzCommand {
        let named = methodParams[method] ?? []
        var params: [String: JSONValue] = [:]
        for key in named where !rng.oneIn(4) {
            params[key] = paramValue(&rng, key: key, catalog: catalog, daemon: daemon)
        }
        for _ in 0..<rng.below(named.isEmpty ? 4 : 2) {
            let key = rng.element(of: generalKeys) ?? "id"
            params[key] = paramValue(&rng, key: key, catalog: catalog, daemon: daemon)
        }
        return envelope(&rng, step: step, method: method, params: params)
    }

    static func paramValue(_ rng: inout FuzzRNG, key: String, catalog: ControlCatalog, daemon: RouterFuzzDaemon) -> JSONValue {
        if rng.oneIn(8) { return randomJSON(&rng) }
        switch key {
        case "tab", "id", "workspace_id", "terminal_id":
            return .string(object(&rng, daemon: daemon).id)
        case "target":
            return target(&rng, kinds: kinds, daemon: daemon)
        case "path", "key":
            let path = rng.element(of: settingsPaths) ?? ""
            return rng.oneIn(4) ? .array(path.split(separator: ".", omittingEmptySubsequences: false).map { JSONValue.string(String($0)) }) : .string(path)
        case "paths":
            var paths: [JSONValue] = []
            for _ in 0..<rng.below(4) {
                paths.append(.string(rng.oneIn(16) ? huge(&rng) : rng.element(of: ["/tmp/cmux-fuzz/a.md", "relative.txt", "", "/"]) ?? ""))
            }
            return .array(paths)
        case "value":
            return rng.oneIn(2) ? .string(rng.element(of: ["compact", "comfortable"]) ?? "compact") : randomJSON(&rng)
        case "url":
            return .string(rng.oneIn(16) ? huge(&rng) : rng.element(of: urls) ?? "")
        case "action", "cli_name":
            let action = rng.element(of: catalog.actions)
            return .string(rng.bool() ? action?.id ?? "" : action?.cliName ?? "")
        case "category":
            return .string(rng.element(of: catalog.actions)?.category ?? "tab")
        case "after", "over_budget_after":
            return after(&rng, daemon: daemon)
        case "caller":
            return caller(&rng, daemon: daemon)
        case "origin":
            return origin(&rng)
        case "limit":
            return edgeNumber(&rng)
        case "where":
            return .string(rng.element(of: ["tab", "editor", "elsewhere"]) ?? "tab")
        default:
            return flag(&rng)
        }
    }

    // MARK: - Values

    static func key(_ rng: inout FuzzRNG) -> JSONValue {
        switch rng.below(10) {
        case 0: .string("")
        case 1: .string(String(repeating: "k", count: 201))
        case 2: JSONValue(rng.int(in: 0...9))
        default: .string(rng.element(of: keys) ?? "k-a")
        }
    }

    /// A read barrier: `"sync"`, a sequence the daemon reached, a future one (the request waits
    /// to its deadline), or a value that is no sequence.
    static func after(_ rng: inout FuzzRNG, daemon: RouterFuzzDaemon) -> JSONValue {
        switch rng.below(8) {
        case 0, 1: return "sync"
        case 2: return .number(Double(daemon.sequence))
        case 3: return .string(String(daemon.sequence))
        case 4: return rng.oneIn(4) ? .number(Double(daemon.sequence + 1)) : .number(0)
        case 5: return rng.element(of: [JSONValue.number(-1), .number(0.5), .number(1e300), .string("soon"), .bool(true)]) ?? .null
        default: return .null
        }
    }

    static func caller(_ rng: inout FuzzRNG, daemon: RouterFuzzDaemon) -> JSONValue {
        guard !rng.oneIn(4) else { return randomJSON(&rng) }
        let terminal = rng.element(of: daemon.live.filter { $0.kind == "terminal" })?.id ?? "term-00000"
        return ["agent_session": .string(FuzzJSON.randomString(&rng)), "terminal_id": .string(terminal), "home_chat": .bool(rng.bool())]
    }

    static func origin(_ rng: inout FuzzRNG) -> JSONValue {
        rng.oneIn(4) ? randomJSON(&rng) : .string(rng.element(of: ["user", "cli", "mcp", "script", "remote", "native"]) ?? "cli")
    }

    static func flag(_ rng: inout FuzzRNG) -> JSONValue {
        rng.oneIn(4) ? randomJSON(&rng) : .bool(rng.bool())
    }

    static func edgeNumber(_ rng: inout FuzzRNG) -> JSONValue {
        let edges: [JSONValue] = [
            .number(0), .number(-1), .number(0.5), .number(-0.0), .number(1e15), .number(1e300), .number(Double(Int64.max)),
            .number(Double(Int64.min)), .string("12"), .string(" 3 "), .string("99999999999999999999"),
        ]
        return rng.element(of: edges) ?? .number(0)
    }

    /// 4 Ki to 256 Ki copies of one unit (up to 1 MiB of UTF-8): quotes, escapes, a NUL, an emoji, a kind prefix.
    static func huge(_ rng: inout FuzzRNG) -> String {
        let unit = rng.element(of: ["a", "é", "\u{1F600}", "\\\"", "\u{0}", "tab:", "{"]) ?? "a"
        return String(repeating: unit, count: 1 << rng.int(in: 12...18))
    }

    static func randomJSON(_ rng: inout FuzzRNG, notOf excluded: [FuzzJSON.Kind] = []) -> JSONValue {
        jsonValue(FuzzJSON.random(&rng, notOf: excluded, depth: 2))
    }

    static func jsonValue(_ value: FuzzJSON) -> JSONValue {
        switch value {
        case .null: .null
        case .bool(let flag): .bool(flag)
        case .int(let number): .number(Double(number))
        case .uint(let number): .number(Double(number))
        case .double(let number): .number(number)
        case .string(let text): .string(text)
        case .array(let items): .array(items.map { jsonValue($0) })
        case .object(let fields): .object(fields.mapValues { jsonValue($0) })
        }
    }
}
