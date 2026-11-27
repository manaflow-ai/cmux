public import CmuxNextCloud
public import CmuxNextDaemon
public import Foundation

/// A Cloud start's create and launch rules, asked of Rust (cmux-cloud-start-core `create_flow`, `grow_disk`
/// and `start_session`, with their tests; ops `cloud_launch_*`): the plan gate, the default machine, the
/// create's params, the approval loop as a step machine, a disk's growth and a start-session run's checks.
extension CloudStartCore {
    /// Whether the plan lets a create go out.
    public enum LaunchGate: Equatable, Sendable { case allowed, freePlan, atLimit(Int) }

    /// The plan gate from the last known limits; unknown limits, a cap the server makes room at (`makesRoom`),
    /// or an FFI that does not answer leave it to the server.
    public func launchGate(_ limits: CloudMachineLimits?, makesRoom: Bool) -> LaunchGate {
        struct Request: Encodable { var limits: CloudMachineLimits?, makesRoom: Bool }
        struct Reply: Decodable { var gate: String, max: Int? }
        let reply = call("cloud_launch_gate", Request(limits: limits, makesRoom: makesRoom), as: Reply.self)
        switch (reply?.gate, reply?.max) {
        case ("free_plan", _): return .freePlan
        case ("at_limit", let max?): return .atLimit(max)
        default: return .allowed
        }
    }

    /// The default machine named `name` (trimmed; empty is none): 2 vCPU, 4 GB, 20 GB disk.
    public func defaultMachine(named name: String?) -> (name: String?, cpu: Int, memoryMb: Int, diskMb: Int) {
        struct Request: Encodable { var name: String? }
        struct Reply: Decodable { var name: String?, cpu: Int, memoryMb: Int, diskMb: Int }
        let reply = call("cloud_launch_named", Request(name: name), as: Reply.self)
        return reply.map { ($0.name, $0.cpu, $0.memoryMb, $0.diskMb) } ?? (name, 2, 4096, 20480)
    }

    /// The create's op, its args (what the approval holds) and the options the backend checks first (never sent);
    /// nil when the FFI does not answer.
    public func createParams(name: String?, environment: String?, cpu: Int, memoryMb: Int, diskMb: Int,
                             request: CloudMachineRequest?) -> (op: String, args: JSONValue, options: JSONValue)? {
        struct Script: Encodable { var kind: String, contentsBase64: String, repo: String? }
        struct Request: Encodable {
            var name, environment: String?
            var cpu, memoryMb, diskMb: Int
            var sizeName: String?, persistent: Bool, script: Script?, machineConfigBase64: String?
        }
        struct Reply: Decodable { var op: String, args: JSONValue, options: JSONValue }
        let script = request?.script.map { Script(kind: $0.kind.rawValue, contentsBase64: $0.contents.base64EncodedString(), repo: $0.repo?.spec) }
        let asked = Request(name: name, environment: environment, cpu: cpu, memoryMb: memoryMb, diskMb: diskMb, sizeName: request?.size,
                            persistent: request?.persistent ?? false, script: script,
                            machineConfigBase64: request?.machineConfig.map { $0.contents?.base64EncodedString() ?? "" })
        return call("cloud_launch_create_params", asked, as: Reply.self).map { ($0.op, $0.args, $0.options) }
    }

    /// The pause before same-key call `attempt` after the approval: 250 ms, 500 ms, then 1 s.
    public func launchBackoff(_ attempt: Int) -> Duration {
        struct Request: Encodable { var attempt: Int }
        struct Reply: Decodable { var ms: Int }
        return .milliseconds(call("cloud_launch_backoff", Request(attempt: attempt), as: Reply.self)?.ms ?? 1000)
    }

    /// How a resize the grow asked for failed: the plan `locked` the disk at `planMax` (`largest` bytes), or not.
    public enum GrowAnswer: Equatable, Sendable { case locked(planMax: String, largest: Int64), failed }

    /// The next step of growing a disk: resize to `diskMb`, or stop (`pastPlan` naming the size the chat needs past).
    public enum GrowStep: Equatable, Sendable { case resize(diskMb: Int), pastPlan(String), notGrown }

    /// The step after `answer` (nil: the first), for a chat whose disk needs `floor` bytes and wants `needed`.
    public func growStep(floor: Int64?, needed: Int64?, maxDisk: Int64, answer: GrowAnswer?, retried: Bool) -> GrowStep {
        struct Sizes: Encodable { var floor: Int64?, needed: Int64?, maxDisk: Int64 }
        struct Answer: Encodable {
            var answer: String, planMax: String?, largest: Int64?
            private enum CodingKeys: String, CodingKey { case answer, planMax = "plan_max", largest }
        }
        struct Request: Encodable { var sizes: Sizes, answer: Answer?, retried: Bool }
        struct Reply: Decodable { var `do`: String, diskMb: Int?, size: String? }
        let wire = answer.map { answer -> Answer in
            if case .locked(let plan, let largest) = answer { return Answer(answer: "locked", planMax: plan, largest: largest) }
            return Answer(answer: "failed", planMax: nil, largest: nil)
        }
        let asked = Request(sizes: Sizes(floor: floor, needed: needed, maxDisk: maxDisk), answer: wire, retried: retried)
        let reply = call("cloud_launch_grow_step", asked, as: Reply.self)
        switch (reply?.do, reply?.diskMb, reply?.size) {
        case ("resize", let mb?, _): return .resize(diskMb: mb)
        case ("past_plan", _, let size?): return .pastPlan(size)
        default: return .notGrown
        }
    }

    /// A start-session run, as `start_session::Request` spells it.
    public struct LaunchRun: Codable, Equatable, Sendable {
        public var machineId, name: String?
        public var agent: String
        public var cwd, fromFolder, model: String?
        /// `--connection`: the local model connection this launch uses, independent of the account scope.
        public var connection: String?

        public init(machineId: String?, name: String?, agent: String, cwd: String?, fromFolder: String?, model: String?, connection: String?) {
            (self.machineId, self.name, self.agent, self.cwd, self.fromFolder, self.model, self.connection) = (machineId, name, agent, cwd, fromFolder, model, connection)
        }

        /// Which argument a run refused: `--agent` (also when the FFI does not answer), `--cwd` or `--connection`.
        public enum Invalid: Error, Equatable { case agent, cwd, connection }
    }

    /// The run's arguments, checked and trimmed: `--agent` a harness id, `--cwd` an absolute folder, `--connection` a connection id (the machine checks the model).
    public func launchRun(agent: String?, cwd: String?, name: String?, model: String?, machineId: String?, connection: String?) -> Result<LaunchRun, LaunchRun.Invalid> {
        struct Request: Encodable { var agent, cwd, name, model, machineId, connection: String? }
        struct Reply: Decodable { var request: LaunchRun?, invalid: String? }
        let reply = call("cloud_launch_session_request", Request(agent: agent, cwd: cwd, name: name, model: model, machineId: machineId, connection: connection), as: Reply.self)
        if let run = reply?.request { return .success(run) }
        return .failure(reply?.invalid == "cwd_invalid" ? .cwd : reply?.invalid == "connection_invalid" ? .connection : .agent)
    }

    /// The command that asks for `run` again, every word as the shell reads it back.
    public func launchCommand(_ run: LaunchRun) -> String {
        struct Reply: Decodable { var command: String }
        return call("cloud_launch_session_command", run, as: Reply.self)?.command ?? "cmux cloud start-session"
    }

    /// How a start's refusal reads: the session needs a folder, a refusal `code` with its own sentence, or the agent failed for `reason`.
    public enum LaunchFailure: Equatable, Sendable { case needsFolder, named(String), failed(reason: String) }

    /// The refusal `code` (nil: not a start refusal) with `message`; `named` are the codes with their own sentence.
    public func launchFailure(code: String?, message: String, folderNeeded: String, named: Set<String>) -> LaunchFailure {
        struct Request: Encodable { var code: String?, message: String, folderNeeded: String, named: [String] }
        struct Reply: Decodable { var kind: String, code: String?, reason: String? }
        let reply = call("cloud_launch_session_failure", Request(code: code, message: message, folderNeeded: folderNeeded, named: named.sorted()), as: Reply.self)
        switch (reply?.kind, reply?.code) {
        case ("needs_folder", _): return .needsFolder
        case ("named", let code?): return .named(code)
        default: return .failed(reason: reply?.reason ?? CloudStartCore.reason(message))
        }
    }

    /// `--from-folder` as written: none, refused beside `--cwd`, invalid, or a `path` to check on this Mac that names `folder`.
    public enum LaunchFolder: Equatable, Sendable { case none, withCwd, invalid, check(path: String, folder: String) }

    public func launchFolder(_ text: String?, hasCwd: Bool) -> LaunchFolder {
        struct Request: Encodable { var text: String?, hasCwd: Bool }
        struct Reply: Decodable { var kind: String, path: String?, folder: String? }
        let reply = call("cloud_launch_from_folder", Request(text: text, hasCwd: hasCwd), as: Reply.self)
        switch (reply?.kind, reply?.path, reply?.folder) {
        case ("none", _, _): return .none
        case ("with_cwd", _, _): return .withCwd
        case ("check", let path?, let folder?): return .check(path: path, folder: folder)
        default: return .invalid
        }
    }
}

/// The approval loop of a Cloud money op as a step machine (cmux-cloud-start-core `create_flow::step`,
/// `cloud_launch_approval_step`): the app makes the call, prompt, answer or pause each effect names and
/// sends back what it heard; times are milliseconds on the app's own clock.
public struct CloudLaunchApproval: Sendable {
    public enum Event: Sendable {
        case start(confirmed: Bool, earlier: String?, patienceMs: Int, nowMs: Int)
        case answered, pending(request: String?, nowMs: Int), asked(yes: Bool), paused
        /// The approval answer went out: `done`, `already_answered` or `answered_elsewhere`.
        case approved(outcome: String, nowMs: Int)
    }

    public enum Effect: Equatable, Sendable {
        case call, done, ask(String), approve(String), recordApproved(String), pause(attempt: Int)
        case declined, stillPending(String), noApprovalRequest
    }

    private var state: JSONValue = .object(["confirmed": .bool(false), "attempt": .number(0), "waits": .number(0), "patienceMs": .number(0), "passes": .number(0)])

    public init() {}

    /// The effects after `event`; nil when the FFI does not answer.
    public mutating func next(_ event: Event) -> [Effect]? {
        struct Request: Encodable { var state: JSONValue, event: JSONValue }
        struct Reply: Decodable {
            struct Effect: Decodable {
                struct Failed: Decodable { var kind: String, request: String? }
                var `do`: String, request: String?, attempt: Int?, failure: Failed?
            }
            var state: JSONValue, effects: [Effect]
        }
        guard let reply = CloudStartCore().call("cloud_launch_approval_step", Request(state: state, event: Self.wire(event)), as: Reply.self) else { return nil }
        state = reply.state
        return reply.effects.compactMap { effect in
            switch (effect.do, effect.failure?.kind) {
            case ("call", _): .call
            case ("done", _): .done
            case ("ask", _): .ask(effect.request ?? "")
            case ("approve", _): .approve(effect.request ?? "")
            case ("record_approved", _): .recordApproved(effect.request ?? "")
            case ("pause", _): .pause(attempt: effect.attempt ?? 0)
            case ("fail", "declined"): .declined
            case ("fail", "no_approval_request"): .noApprovalRequest
            case ("fail", _): .stillPending(effect.failure?.request ?? "")
            default: nil
            }
        }
    }

    private static func wire(_ event: Event) -> JSONValue {
        let ms = { (value: Int) in JSONValue.number(Double(max(value, 0))) }
        return switch event {
        case .start(let confirmed, let earlier, let patience, let now):
            .object(["event": .string("start"), "confirmed": .bool(confirmed), "earlier": earlier.map(JSONValue.string) ?? .null, "patience_ms": ms(patience), "now_ms": ms(now)])
        case .answered: .object(["event": .string("answered")])
        case .pending(let request, let now): .object(["event": .string("pending"), "request": request.map(JSONValue.string) ?? .null, "now_ms": ms(now)])
        case .asked(let yes): .object(["event": .string("asked"), "yes": .bool(yes)])
        case .approved(let outcome, let now): .object(["event": .string("approved"), "outcome": .string(outcome), "now_ms": ms(now)])
        case .paused: .object(["event": .string("paused")])
        }
    }
}
