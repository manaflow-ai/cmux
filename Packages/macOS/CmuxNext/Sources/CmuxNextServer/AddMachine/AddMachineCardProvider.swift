public import CmuxNextPages
public import AppKit
public import CmuxNextSettings

/// Add Machine and Check Machine on the server card page (`#/add-machine`,
/// webviews/src/pages/server-cards/add-machine, plans/cmux-next/add-machine-DESIGN.md). Swift keeps
/// the runs (``AddMachineRuns``: the CLI, the app's install fallback, connect, the health record);
/// the page derives its layout, checklist, buttons and Copy Details from `status`:
/// - `status` → `{request, run?}`: what opened the card (its `seq` moves on every open) and the run
///   in flight with its events;
/// - `parse {text}` → `{host, shortName}` or null: the field read as ssh takes it;
/// - `candidates {probe}` → the tailnet's machines, or null without Tailscale;
/// - `add {destination, name, peer?}` → Add and Try Again, only from the person's own click or key
///   in the card: a destination from outside the app (the CLI, MCP) only fills the field;
/// - `fix` → `doctor --fix` for the checked machine, only from the person's own click or key;
/// - `openWorkspace` and `copy {text}`, only from the person's own click or key; `cancel`;
/// - stream `changes` → one empty event whenever `status` may have changed.
@MainActor
public final class AddMachineCardProvider: WebCard {
    public static let route = "add-machine"
    static let statusOp = "cmux.addMachine.status"
    static let parseOp = "cmux.addMachine.parse"
    static let candidatesOp = "cmux.addMachine.candidates"
    static let addOp = "cmux.addMachine.add"
    static let fixOp = "cmux.addMachine.fix"
    static let cancelOp = "cmux.addMachine.cancel"
    static let openWorkspaceOp = "cmux.addMachine.openWorkspace"
    static let copyOp = "cmux.addMachine.copy"
    static let changesStream = "cmux.addMachine.changes"

    public var card: String { Self.route }
    public var prefix: String { "cmux.addMachine." }
    public weak var host: WebCardPanel?

    public let runs: AddMachineRuns
    private var listeners: [Int: @MainActor (JSONValue) -> Void] = [:]
    private var nextListener = 0

    public init(runs: AddMachineRuns) {
        self.runs = runs
        runs.changed = { [weak self] in self?.notify() }
    }

    public func opened(again: Bool) {}

    /// A run keeps going when the card closes; a reopen shows it again.
    public func closed() {}

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.statusOp:
            return Self.status(runs)
        case Self.parseOp:
            guard let parsed = runs.parse(params["text"]?.stringValue ?? "") else { return .null }
            return ["host": .string(parsed.host), "shortName": .string(parsed.shortName)]
        case Self.candidatesOp:
            guard let list = await runs.candidates(probe: params["probe"]?.boolValue == true) else { return .null }
            return .array(list.map(Self.candidate))
        case Self.addOp:
            try personOnly(context)
            guard let destination = params["destination"]?.stringValue, runs.parse(destination) != nil else {
                throw PageError.invalidParams("destination is not a host ssh takes")
            }
            runs.add(destination: destination, name: params["name"]?.stringValue ?? "", peer: params["peer"]?.stringValue)
        case Self.fixOp:
            try personOnly(context)
            runs.fix()
        case Self.cancelOp:
            runs.cancel()
        case Self.openWorkspaceOp:
            try personOnly(context)
            runs.openWorkspace()
        case Self.copyOp:
            try personOnly(context)
            guard let text = params["text"]?.stringValue else { throw PageError.invalidParams("text is required") }
            runs.copy(text)
        default:
            throw PageError.unknownOp(op)
        }
        return .null
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.changesStream else { throw PageError.unknownOp(stream) }
        let id = nextListener
        nextListener += 1
        listeners[id] = onEvent
        return PageSubscription { [weak self] in _ = self?.listeners.removeValue(forKey: id) }
    }

    /// One empty event to every page listening: `status` may have changed.
    private func notify() {
        for listener in listeners.values { listener(.object([:])) }
    }

    /// The person's own click or key in the card; a script, MCP or the CLI never adds, fixes, copies
    /// from or opens a workspace on a machine.
    private func personOnly(_ context: PageCallContext) throws {
        guard context.userGesture else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: AddMachineStrings.personOnly)
        }
    }

    // MARK: - The wire

    static func status(_ runs: AddMachineRuns) -> JSONValue {
        var reply: [String: JSONValue] = ["request": request(runs.request)]
        if let run = runs.run { reply["run"] = Self.run(run) }
        return .object(reply)
    }

    static func request(_ request: AddMachineRuns.Request) -> JSONValue {
        let mode: JSONValue = switch request.mode {
        case .add: ["kind": "add"]
        case let .check(host, machineID): ["kind": "check", "host": .string(host), "machineID": .string(machineID)]
        case let .checkJoined(id, name, _): ["kind": "checkJoined", "id": .string(id), "name": .string(name)]
        }
        var reply: [String: JSONValue] = ["seq": JSONValue(request.seq), "mode": mode]
        if let destination = request.destination { reply["destination"] = .string(destination) }
        if let name = request.name { reply["name"] = .string(name) }
        return .object(reply)
    }

    static func run(_ run: AddMachineRuns.Run) -> JSONValue {
        var reply: [String: JSONValue] = [
            "id": JSONValue(run.id), "host": .string(run.host), "name": .string(run.name),
            "outcome": .string(run.outcome.rawValue), "events": .array(run.events.map(event)),
        ]
        if let id = run.machineID { reply["machineID"] = .string(id) }
        if let destination = run.destination { reply["destination"] = .string(destination) }
        if let peer = run.peer { reply["peer"] = .string(peer) }
        return .object(reply)
    }

    static func event(_ event: AddMachineRuns.Event) -> JSONValue {
        switch event {
        case let .start(joined): ["kind": "start", "joined": .bool(joined)]
        case let .line(line): ["kind": "line", "line": .string(line)]
        case .install: ["kind": "install"]
        case .installEnd: ["kind": "installEnd"]
        case let .stop(detail): ["kind": "stop", "detail": .string(detail)]
        }
    }

    static func candidate(_ candidate: HostCandidate) -> JSONValue {
        var reply: [String: JSONValue] = [
            "id": .string(candidate.id), "name": .string(candidate.name), "os": .string(candidate.os),
            "online": .bool(candidate.online), "alreadyPeer": .bool(candidate.alreadyPeer), "inApp": .bool(candidate.inApp),
            "destination": .string(candidate.destination), "pickable": .bool(candidate.isPickable),
        ]
        if let peer = candidate.peer { reply["peer"] = .string(peer) }
        if let ssh = candidate.sshOK { reply["sshOK"] = .bool(ssh) }
        return .object(reply)
    }
}

/// Add Machine and Check Machine for the app: the runs, the card's provider, and the opening of the
/// server card panel on `#/add-machine`. Made once and kept, so a run in flight survives the card
/// closing and a reopen shows it again.
@MainActor
public final class AddMachineCard {
    public let runs: AddMachineRuns
    public let provider: AddMachineCardProvider
    /// The server card panel the card shows on (nil in tests and previews).
    private let panel: @MainActor () -> WebCardPanel?

    public init(services: AddMachineServices, panel: @escaping @MainActor () -> WebCardPanel? = { nil }) {
        runs = AddMachineRuns(services: services)
        provider = AddMachineCardProvider(runs: runs)
        self.panel = panel
    }

    /// Shows `#/add-machine` over `window`, with the keys (Add Machine is always opened by hand or
    /// by a person's click elsewhere).
    private func present(_ route: String, _ window: NSWindow?) {
        panel()?.present(card: route, over: window, takeKeys: true)
    }

    /// Opens Add Machine over `window`. A destination (the CLI, MCP, a script) only fills the field:
    /// the add starts when the person presses Add. The card takes the keys for its field.
    public func open(destination: String? = nil, name: String? = nil, over window: NSWindow?) {
        runs.begin(destination: destination, name: name)
        present(AddMachineCardProvider.route, window)
    }

    /// Opens Add Machine and starts the add at once: a person's own click elsewhere (Add Device's
    /// Any Computer way) already chose the host.
    public func add(destination: String, name: String?, over window: NSWindow?) {
        runs.begin(destination: destination, name: name)
        runs.add(destination: destination, name: name ?? "")
        present(AddMachineCardProvider.route, window)
    }

    /// Opens Check Machine for an SSH machine the app has and runs doctor.
    public func check(host: String, machineID: String, over window: NSWindow?) {
        runs.beginCheck(host: host, machineID: machineID)
        present(AddMachineCardProvider.route, window)
    }

    /// Opens Check for a machine that joined with a one-line token and runs `machine doctor ID`.
    public func checkJoined(id: String, name: String, rowID: String? = nil, over window: NSWindow?) {
        runs.beginJoinedCheck(id: id, name: name, rowID: rowID)
        present(AddMachineCardProvider.route, window)
    }

    /// Nil once the run in flight ended ready, else why not.
    public func finished() async -> String? {
        await runs.finished()
    }
}
