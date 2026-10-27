import CmuxFuzzSupport
import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// Stateful ControlRouter fuzz (p10-stability-177): random sequences of control-socket lines,
/// built from the registered action catalog (`ActionRegistry.standard()`) and the router's own
/// methods, go through `ControlRouter.response(forLine:)` off the main actor, as a socket
/// connection sends them, with ``RouterFuzzDaemon`` as the executor and the topology's owner.
/// Targets name live objects, objects the daemon closed earlier in the sequence and bogus ids;
/// values are right, wrong-typed or huge; idempotency keys repeat; the daemon fails, refuses,
/// stalls, disconnects and changes the topology between commands. The shape is Chrome's stateful
/// IPC fuzzing (MojoLPM, mojo/public/tools/fuzzers/; content/test/fuzzer/ for the interfaces): a
/// sequence of calls against one live receiver, so state from one call meets the next.
///
/// After every command:
/// - the reply is one line: `PONG` or `ERROR: …` for a v1 line, else a JSON object with `ok`
///   and `result`, or a typed error (`code` and `message`, never `internal_error`, which means
///   an untyped error escaped), echoing the request's `id`;
/// - the daemon got nothing validation refuses: an unregistered action, an argument outside its
///   schema, a target it closed before the step;
/// - in a fleet run only (long mode, or `CMUX_FUZZ_TURN_BUDGET=1` for a replay), no main-actor
///   turn of the router's work queue took more than 50 ms: a wall-clock budget is fleet evidence,
///   so the default run (CI's) checks replies and the audit, never time.
/// A trap ends the test process; with `CMUX_FUZZ_ARTIFACTS` set the run leaves the in-flight
/// replay line. A failure prints the replay variables and the sequence up to the failing reply.
/// Long mode: `CMUX_FUZZ_SECONDS=600`.
@MainActor
@Suite struct ControlRouterFuzzTests {
    static let turnBudget: Duration = .milliseconds(50)
    static let maxSteps = 24
    /// Short, so a command whose work stalls answers `timeout` quickly; a request that misses it on a
    /// loaded host is still a typed error. A method with a longer limit never waits on a future
    /// barrier (``barrierPastDeadline(_:router:daemon:)``).
    static let deadline: Duration = .milliseconds(400)
    nonisolated static let v1Answer = "OK"
    static let turnBudgetVariable = "CMUX_FUZZ_TURN_BUDGET"

    /// Whether `environment`'s run checks ``turnBudget``: long mode, or the variable set to `1`.
    static func checksTurnBudget(_ environment: FuzzEnvironment, variables: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment.isLongMode || variables[turnBudgetVariable] == "1"
    }

    @Test func commandSequencesGetAReplyOrATypedError() async throws {
        let catalog = Self.registeredCatalog()
        try #require(!catalog.actions.isEmpty)
        let run = try FuzzRun("ControlRouter.sequences", seed: 0xC0_17_01_77, iterations: 96)
        let checksTurnBudget = Self.checksTurnBudget(run.environment)
        try await run.forEachAwaiting { rng in try await Self.sequence(&rng, catalog: catalog, checksTurnBudget: checksTurnBudget) }
    }

    @Test func oneInputTakesAnyBytes() async throws {
        let run = try FuzzRun("ControlRouter.oneInput", seed: 0xC0_17_01_78, iterations: 32)
        // Choice tapes: the daemon's seed (8 bytes), the step count, then the first command's choices.
        let tapes: [[UInt8]] = [[], [1, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0], [7, 7, 7, 7, 7, 7, 7, 7, 23, 9, 12, 1]]
        let checksTurnBudget = Self.checksTurnBudget(run.environment)
        try await run.forEachInputAwaiting(run.corpus(seeds: tapes.map { Data($0) })) { data in
            try await Self.oneInput(data, checksTurnBudget: checksTurnBudget)
        }
    }

    /// The default run, as CI runs it, times nothing; a fleet run opts in.
    @Test func onlyAFleetRunChecksTheTurnBudget() throws {
        let ci = try FuzzEnvironment(variables: [:])
        let long = try FuzzEnvironment(variables: ["CMUX_FUZZ_SECONDS": "600"])
        #expect(!Self.checksTurnBudget(ci, variables: [:]))
        #expect(!Self.checksTurnBudget(ci, variables: [Self.turnBudgetVariable: "0"]))
        #expect(Self.checksTurnBudget(long, variables: [:]))
        #expect(Self.checksTurnBudget(ci, variables: [Self.turnBudgetVariable: "1"]))
    }

    /// A batch past the op limit gets past the shape check: atomic, it is `batch_too_large`; not
    /// atomic, it runs as consecutive transactions. Its ops never carry a batch-level member.
    @Test func largeBatchesReachTheOpLimit() throws {
        let catalog = Self.registeredCatalog()
        let daemon = RouterFuzzDaemon(catalog: catalog, seed: 2, scripted: false)
        var rng = FuzzRNG(seed: 0xC0_17_01_79)
        var (shapedBatches, validBatches) = (0, 0)
        for _ in 0..<64 {
            let ops = Self.batchOps(&rng, count: 66, catalog: catalog, daemon: daemon)
            guard let shaped = try? ControlRouter.batchOps(["ops": .array(ops)]) else { continue }
            shapedBatches += 1
            let valid = shaped.allSatisfy { op in
                guard let action = try? ControlRouter.resolveAction(op, in: catalog) else { return false }
                return (try? ControlRouter.validatedRequest(for: action, params: op, knownKinds: catalog.targetKinds, connection: .inProcess)) != nil
            }
            if valid { validBatches += 1 }
        }
        #expect(shapedBatches >= 32, "only \(shapedBatches) of 64 large batches got past the shape check")
        #expect(validBatches >= 16, "only \(validBatches) of 64 large batches validate every op")
    }

    /// A future barrier on a method whose limit is longer than the deadline is caught before it
    /// holds a step; on a method with the control-plane deadline it is sent as it is.
    @Test func aFutureBarrierNeverOutlivesTheDeadline() throws {
        let catalog = Self.registeredCatalog()
        let daemon = RouterFuzzDaemon(catalog: catalog, seed: 3, scripted: false)
        let router = Self.makeRouter(daemon: daemon, catalog: catalog)
        let future = JSONValue.number(Double(daemon.sequence + 1))
        func line(_ method: String, _ params: [String: JSONValue]) -> String {
            JSONValue.object(["id": "b1", "method": .string(method), "params": .object(params)]).compactText
        }
        #expect(Self.barrierPastDeadline(line("settings.set", ["path": "ui.animationSpeed", "value": .number(1), "after": future]),
                                         router: router, daemon: daemon) == daemon.sequence + 1)
        #expect(Self.barrierPastDeadline(line("settings.set", ["path": "ui.animationSpeed", "value": .number(1), "after": .number(Double(daemon.sequence))]),
                                         router: router, daemon: daemon) == nil)
        #expect(Self.barrierPastDeadline(line("system.ping", ["after": future]), router: router, daemon: daemon) == nil)
        #expect(Self.barrierPastDeadline(line("debug.hangs", ["after": future]), router: router, daemon: daemon) == nil)
    }

    /// The fuzz's own checks are not vacuous: the oracle refuses what a broken router would send.
    @Test func theReplyCheckRefusesBrokenReplies() throws {
        let command = RouterFuzzCommand(line: "{}", isJSON: true, expectedID: .string("f0"), method: "system.ping")
        #expect(throws: FuzzError.self) { try Self.checkLine(#"{"error":{"code":"internal_error","message":"x"},"id":"f0","ok":false}"#, answering: command) }
        #expect(throws: FuzzError.self) { try Self.checkLine(#"{"error":{"message":"x"},"id":"f0","ok":false}"#, answering: command) }
        #expect(throws: FuzzError.self) { try Self.checkLine(#"{"id":"f1","ok":true,"result":{}}"#, answering: command) }
        #expect(throws: FuzzError.self) { try Self.checkLine("{\"id\":\"f0\",\"ok\":true,\"result\":{}}\n{}", answering: command) }
        #expect(throws: FuzzError.self) { try Self.checkLine("not json", answering: command) }
        #expect(throws: FuzzError.self) { try Self.checkLine("hello", answering: Self.raw("ping")) }
        try Self.checkLine(#"{"id":"f0","ok":true,"result":{"pong":true}}"#, answering: command)
        try Self.checkLine("PONG", answering: Self.raw("ping"))
    }

    /// The daemon's audit sees what the router passes: a target the daemon closed is `not_found`
    /// before any handler runs, and the same action on a live target reaches the daemon.
    @Test func aClosedTargetNeverReachesTheDaemon() async throws {
        let catalog = Self.registeredCatalog()
        let action = try #require(catalog.actions.first { action in
            action.targets.contains("workspace") && !action.isDestructive && !action.isDebugOnly && action.requiresMask == 0
                && action.unavailableReason == nil && action.disabledFeature == nil && action.arguments.allSatisfy { !$0.isRequired }
        })
        let daemon = RouterFuzzDaemon(catalog: catalog, seed: 1, scripted: false)
        let router = Self.makeRouter(daemon: daemon, catalog: catalog)
        let closed = try #require(daemon.createWorkspace())
        daemon.close(closed)
        daemon.beginStep()
        let refused = try await Self.call(router, ["action": .string(action.id), "target": .string("workspace:" + closed)])
        #expect(refused["error"]?["code"] == .string("not_found"), "\(refused)")
        #expect(daemon.calls == 0)
        let live = try #require(daemon.live.first { $0.kind == "workspace" })
        let ran = try await Self.call(router, ["action": .string(action.id), "target": .string("workspace:" + live.id)])
        #expect(ran["ok"] == .bool(true), "\(ran)")
        #expect(daemon.calls == 1)
        #expect(daemon.violations.isEmpty, "\(daemon.violations)")
    }

    // MARK: - Driving

    /// One sequence; its choices read from `data` (the libFuzzer entry, p10-stability-182).
    static func oneInput(_ data: Data, checksTurnBudget: Bool = false) async throws {
        var rng = FuzzRNG(replaying: data)
        try await sequence(&rng, catalog: registeredCatalog(), checksTurnBudget: checksTurnBudget)
    }

    /// One router and daemon, then 1 to ``maxSteps`` commands drawn from `rng`, each after an
    /// optional daemon event. Throws at the first command whose reply or effect breaks a property.
    static func sequence(_ rng: inout FuzzRNG, catalog: ControlCatalog, checksTurnBudget: Bool) async throws {
        let daemon = RouterFuzzDaemon(catalog: catalog, seed: rng.next())
        let router = makeRouter(daemon: daemon, catalog: catalog)
        defer { daemon.releaseStalls() }
        let methods = router.methodNames
        let steps = rng.int(in: 1...maxSteps)
        var transcript: [String] = []
        for step in 0..<steps {
            if rng.oneIn(4) { daemonEvent(&rng, daemon: daemon, router: router) }
            daemon.beginStep()
            let next = command(&rng, step: step, catalog: catalog, methods: methods, daemon: daemon)
            daemon.mayStall = next.mayStall
            if let barrier = barrierPastDeadline(next.line, router: router, daemon: daemon) {
                // Reach the barrier first (the next sequence, as ``after(_:daemon:)`` draws it), else skip a
                // line mutated past reach: it would wait out the method's long limit, not the deadline.
                guard barrier == daemon.sequence &+ 1 else {
                    transcript.append("> " + clip(next.line) + "\n< (not sent: its barrier \(barrier) waits out a long limit)")
                    continue
                }
                daemon.bumpSequence()
            }
            let connection = ControlConnectionID(rawValue: UInt64(1 + rng.below(3)))
            let reply = await send(next.line, to: router, on: connection)
            transcript.append("> " + clip(next.line) + "\n< " + clip(reply))
            do {
                try checkLine(reply, answering: next)
                try FuzzRun.check(daemon.violations.isEmpty, "the daemon got what the router must refuse: " + daemon.violations.joined(separator: "; "))
                if checksTurnBudget {
                    let longest = router.workQueue.stats.maxFrameWork
                    try FuzzRun.check(longest <= turnBudget, "a main-actor turn of the work queue took \(FuzzBudget.milliseconds(longest)) ms, "
                        + "budget \(FuzzBudget.milliseconds(turnBudget)) ms")
                }
            } catch {
                throw FuzzError.property("step \(step) of \(steps): \(error)\nthe sequence:\n" + transcript.joined(separator: "\n"),
                                         location: "ControlRouterFuzzTests")
            }
        }
    }

    /// A router as the App builds one, with the fuzz daemon behind it: the registered catalog, the
    /// daemon's topology, a sync barrier, a v1 handler and the compat layer's unknown-method error.
    static func makeRouter(daemon: RouterFuzzDaemon, catalog: ControlCatalog) -> ControlRouter {
        let configuration = ControlRouter.Configuration(requestDeadline: deadline, terminalStartDeadline: deadline)
        let router = ControlRouter(identity: testIdentity(), executor: daemon, settings: RouterFuzzSettings(), configuration: configuration)
        router.updateCatalog(catalog)
        daemon.attach(router.snapshots)
        router.registerSyncBarrier { [daemon] in try await daemon.syncSequence() }
        router.registerV1 { line in line.lowercased().hasPrefix("list") ? Self.v1Answer : nil }
        router.registerUnknownMethod { name in
            name.hasPrefix("compat.") ? ControlError(code: "unsupported", message: "unsupported in cmux-next: \(name)") : nil
        }
        return router
    }

    /// The sequence `line`'s read barrier waits for when that is past the daemon's sequence and the
    /// method's limit (as ``ControlRouter/handle(_:connection:)`` picks it) is longer than ``deadline``:
    /// nothing publishes during a step, so the request would wait that whole limit.
    static func barrierPastDeadline(_ line: String, router: ControlRouter, daemon: RouterFuzzDaemon) -> UInt64? {
        guard case .success(let request) = ControlRouter.decode(line), request.method != "debug.hangs",
              let method = router.method(named: request.method),
              let after = request.params["after"].flatMap(ControlRouter.explicitSequence), after > daemon.sequence else { return nil }
        let limit = method.limitOverride?(request, router.snapshots.current) ?? method.fixedLimit ?? deadline
        return limit > deadline ? after : nil
    }

    /// Something the daemon does on its own between commands.
    static func daemonEvent(_ rng: inout FuzzRNG, daemon: RouterFuzzDaemon, router: ControlRouter) {
        switch rng.below(8) {
        case 0, 1:
            daemon.createWorkspace()
        case 2:
            let pane = rng.element(of: daemon.live.filter { $0.kind == "pane" })?.id
            daemon.createTab(in: pane)
        case 3:
            if let object = rng.element(of: daemon.live.filter { $0.kind != "window" && $0.kind != "terminal" }) { daemon.close(object.id) }
        case 4:
            daemon.disconnect(unloaded: rng.bool())
        case 5:
            daemon.reconnect()
        case 6:
            router.updateContextMask(UInt32(truncatingIfNeeded: rng.next()))
        default:
            daemon.bumpSequence()
        }
    }

    /// The router answers on the caller's task: a socket connection's, never the main actor.
    @concurrent nonisolated static func send(_ line: String, to router: ControlRouter, on connection: ControlConnectionID) async -> String {
        await router.response(forLine: line, connection: connection)
    }

    static func call(_ router: ControlRouter, _ params: [String: JSONValue]) async throws -> JSONValue {
        let line = JSONValue.object(["id": "c1", "method": "action.run", "params": .object(params)]).compactText
        let reply = await send(line, to: router, on: .inProcess)
        return try JSONValue.parse(Data(reply.utf8))
    }

    // MARK: - The reply check

    /// One line; for a v2 request a JSON object that echoes its id, with `ok` and a result or a typed error.
    static func checkLine(_ reply: String, answering command: RouterFuzzCommand) throws(FuzzError) {
        try FuzzRun.check(!reply.utf8.contains(0x0A), "the reply is more than one line: " + clip(reply))
        guard command.isJSON else {
            try FuzzRun.check(reply == "PONG" || reply == v1Answer || reply.hasPrefix("ERROR: "), "a v1 line got " + clip(reply))
            return
        }
        guard case .object(let members)? = try? JSONValue.parse(Data(reply.utf8)), let ok = members["ok"]?.boolValue else {
            throw FuzzError.property("the reply is not a JSON object with ok: " + clip(reply), location: "ControlRouterFuzzTests")
        }
        if let expected = command.expectedID {
            try FuzzRun.check((members["id"] ?? .null) == expected, "the reply's id is not the request's \(expected): " + clip(reply))
        }
        guard !ok else {
            try FuzzRun.check(members["result"] != nil, "ok without a result: " + clip(reply))
            if command.method == "action.run" { try FuzzRun.check(members["result"]?["ran"] == .bool(true), "action.run ok without ran: " + clip(reply)) }
            return
        }
        guard case .object(let error)? = members["error"], let code = error["code"]?.stringValue, !code.isEmpty,
              error["message"]?.stringValue != nil else {
            throw FuzzError.property("an error without a code and a message: " + clip(reply), location: "ControlRouterFuzzTests")
        }
        try FuzzRun.check(code != "internal_error", "an untyped error escaped: " + clip(reply))
    }

    static func clip(_ text: String) -> String {
        text.utf8.count <= 300 ? text : String(text.prefix(300)) + "… (\(text.utf8.count) bytes)"
    }

    /// The registered action catalog, built once per process.
    static func registeredCatalog() -> ControlCatalog {
        if let catalog = cachedCatalog { return catalog }
        let catalog = RegistryControlBridge.catalog(from: ActionRegistry.standard())
        cachedCatalog = catalog
        return catalog
    }

    private static var cachedCatalog: ControlCatalog?
}
