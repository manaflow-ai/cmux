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

    /// The `acpmux` arguments that move `chat` to `target` and the session the tab names once
    /// moved, or why it cannot (the person's words).
    public func sshMove(_ chat: Chat, to target: String?, peers: [Peer]) -> Result<(args: [String], moved: String), SSHMoveRefusal> {
        struct Request: Encodable { var chat: Chat, target: String?, peers: [Peer] }
        struct Call: Decodable { var args: [String], moved: String }
        struct Reply: Decodable { var call: Call?, refusal: String? }
        guard let reply = CloudMoveCore().call("ssh_move", Request(chat: chat, target: target, peers: peers), as: Reply.self) else { return .failure(.init(message: "")) }
        guard let call = reply.call else { return .failure(.init(message: reply.refusal ?? "")) }
        return .success((call.args, call.moved))
    }

    /// nil once `acpmux --json session move` moved the chat, else why not in its words.
    public func sshMoveFailure(stdout: String, stderr: String, status: Int32) -> String? {
        struct Request: Encodable { var stdout: String, stderr: String, status: Int32 }
        struct Reply: Decodable { var moved: Bool, error: String? }
        guard let reply = CloudMoveCore().call("ssh_move_outcome", Request(stdout: stdout, stderr: stderr, status: status), as: Reply.self) else { return "" }
        return reply.moved ? nil : reply.error ?? ""
    }
}

/// Why a move to an SSH machine did not start.
public struct SSHMoveRefusal: Error, Sendable {
    public var message: String
}
