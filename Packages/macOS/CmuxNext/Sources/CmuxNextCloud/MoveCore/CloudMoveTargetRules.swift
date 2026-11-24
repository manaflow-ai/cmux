public import Foundation
import CmuxNextDaemon

/// Move to…'s rules, asked of Rust (cmux-cloud-start-core `moves::targets`, with its tests): where a
/// started chat can move, which action takes it there, and the `acpmux session move` call of a move
/// to an SSH machine. The app reads its machine lists and the chat's record and draws the answer.
public nonisolated struct CloudMoveTargetRules: Sendable {
    public init() {}

    public struct Machine: Encodable, Sendable {
        public var id: String, title: String, status: String
        public init(id: String, title: String, status: String) { (self.id, self.title, self.status) = (id, title, status) }
    }

    /// A machine reached over SSH: a sidebar SSH machine, or an acpmux peer (`names`: what acpmux may call it).
    public struct SSHMachine: Encodable, Sendable {
        public var id: String, title: String, online: Bool, names: [String]
        public init(id: String, title: String, online: Bool, names: [String]) { (self.id, self.title, self.online, self.names) = (id, title, online, names) }
    }

    /// One acpmux peer as this Mac's daemon lists it.
    public struct Peer: Encodable, Sendable {
        public var name: String, url: String
        public init(name: String, url: String) { (self.name, self.url) = (name, url) }
    }

    public struct Chat: Encodable, Sendable {
        public var offered: Bool, started: Bool, chief: Bool, running: String?, elsewhere: Bool, backHome: Bool, machines: [Machine]
        public var movedHere: Bool, session: String?, onSsh: String?, peer: String?, ssh: [SSHMachine]
        public init(offered: Bool, started: Bool, chief: Bool, running: String?, elsewhere: Bool, backHome: Bool, machines: [Machine],
                    movedHere: Bool = false, session: String? = nil, onSsh: String? = nil, peer: String? = nil, ssh: [SSHMachine] = []) {
            (self.offered, self.started, self.chief, self.running) = (offered, started, chief, running)
            (self.elsewhere, self.backHome, self.machines) = (elsewhere, backHome, machines)
            (self.movedHere, self.session, self.onSsh, self.peer, self.ssh) = (movedHere, session, onSsh, peer, ssh)
        }
    }

    /// One row of Move to…: `kind` is `local` (this Mac, label empty), `cloud` or `ssh`; `action` is the
    /// catalog action that moves the chat there.
    public struct Target: Decodable, Equatable, Sendable {
        public var id: String, label: String, status: String?, kind: String, action: String
    }

    /// Every place the chat can move now; none when the FFI does not answer.
    public func targets(_ chat: Chat) -> [Target] {
        struct Reply: Decodable { var targets: [Target] }
        return CloudMoveCore().call("targets", chat, as: Reply.self)?.targets ?? []
    }

    /// Decodes the daemon-owned target rows away from the UI actor.
    public func paletteReply(_ data: Data) async -> PaletteReply? {
        await Task.detached(priority: .high) {
            try? JSONDecoder().decode(PaletteReply.self, from: data)
        }.value
    }

    public struct PaletteReply: Decodable, Sendable {
        public var targets: [Row]
        public struct Row: Decodable, Sendable {
            public var id: String, label: String, status: String?, reason: String?
        }
    }

    /// Options that resolve one of the move preflight refusals. The UI asks the person once and
    /// invokes the same action again with one of these flags; the Rust move remains the owner of
    /// the running-turn and dirty-worktree checks.
    public struct MoveOptions: Encodable, Sendable {
        public var afterTurn = false
        public var interrupt = false
        public var carryChanges = false
        public var leaveDirty = false
        public var dryRun = false
        public init(afterTurn: Bool = false, interrupt: Bool = false, carryChanges: Bool = false,
                    leaveDirty: Bool = false, dryRun: Bool = false) {
            self.afterTurn = afterTurn; self.interrupt = interrupt; self.carryChanges = carryChanges
            self.leaveDirty = leaveDirty; self.dryRun = dryRun
        }
    }

    public enum MoveResult: Sendable, Equatable {
        case moved(session: String)
        case refused(code: String)
        case needsConfirmation(code: String, dirty: Bool?)
        case failed(String)
    }

    /// The `acpmux` arguments that move `chat` to `target` and the session the tab names once
    /// moved, or why it cannot (the person's words).
    public func sshMove(_ chat: Chat, to target: String?, peers: [Peer], options: MoveOptions = .init()) -> Result<(args: [String], moved: String, destination: String?, source: String?), SSHMoveRefusal> {
        struct Request: Encodable { var chat: Chat, target: String?, peers: [Peer]; var afterTurn: Bool; var interrupt: Bool; var carryChanges: Bool; var leaveDirty: Bool; var dryRun: Bool }
        struct Call: Decodable { var args: [String], moved: String, destination: String?, source: String? }
        struct Reply: Decodable { var call: Call?, refusal: String? }
        let request = Request(chat: chat, target: target, peers: peers, afterTurn: options.afterTurn, interrupt: options.interrupt,
                              carryChanges: options.carryChanges, leaveDirty: options.leaveDirty, dryRun: options.dryRun)
        guard let reply = CloudMoveCore().call("ssh_move", request, as: Reply.self) else { return .failure(.init(message: "")) }
        guard let call = reply.call else { return .failure(.init(message: reply.refusal ?? "")) }
        return .success((call.args, call.moved, call.destination, call.source))
    }

    /// What the move `call` ran says (`ssh_move_run`): the session the tab opens, the one question, or the failure.
    public func sshMoveRun(stdout: String, stderr: String, status: Int32, moved: String, destination: String?, dryRun: Bool) -> MoveResult {
        struct Request: Encodable { var stdout: String, stderr: String, status: Int32, moved: String, destination: String?, dryRun: Bool }
        struct Reply: Decodable { var kind: String, session: String?, code: String?, dirty: Bool?, message: String? }
        let request = Request(stdout: stdout, stderr: stderr, status: status, moved: moved, destination: destination, dryRun: dryRun)
        let reply = CloudMoveCore().call("ssh_move_run", request, as: Reply.self)
        switch reply?.kind {
        case "moved"?: return .moved(session: reply?.session ?? "")
        case "needs_confirmation"?: return .needsConfirmation(code: reply?.code ?? "", dirty: reply?.dirty)
        default: return .failed(reply?.message ?? "")
        }
    }
}

/// Why a move to an SSH machine did not start.
public struct SSHMoveRefusal: Error, Sendable {
    public var message: String
}

/// Runs the single acpmux move command used by the chat menu, palette and CLI. Rust owns target
/// validation and preflight; this app-side seam only launches the bundled binary and opens the
/// session that the move actually imported.
public nonisolated struct SSHChatMoveRun: Sendable {
    public typealias Outcome = CloudMoveTargetRules.MoveResult

    public static let limit: Duration = .seconds(1_800)
    public let executable: URL
    public let environment: [String: String]

    public init(executable: URL, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    public func run(_ chat: CloudMoveTargetRules.Chat, to target: String?, peers: [CloudMoveTargetRules.Peer],
                    options: CloudMoveTargetRules.MoveOptions = .init()) async -> Outcome {
        let rules = CloudMoveTargetRules()
        let call: (args: [String], moved: String, destination: String?, source: String?)
        switch rules.sshMove(chat, to: target, peers: peers, options: options) {
        case .failure(let refusal): return .refused(code: refusal.message)
        case .success(let made): call = made
        }
        guard let result = try? await ProcessRunner.run(executable: executable, arguments: call.args, environment: environment,
                                                        timeout: Self.limit, clock: ContinuousClock()) else { return .failed("") }
        return rules.sshMoveRun(stdout: String(decoding: result.stdout, as: UTF8.self), stderr: String(decoding: result.stderr, as: UTF8.self),
                                status: result.status, moved: call.moved, destination: call.destination, dryRun: options.dryRun)
    }
}
