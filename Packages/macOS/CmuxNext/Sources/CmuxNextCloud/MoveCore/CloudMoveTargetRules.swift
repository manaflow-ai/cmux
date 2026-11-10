/// Move to…'s rules, asked of Rust (cmux-cloud-start-core `moves::targets`, with its tests): where a
/// started chat can move. The app reads its
/// machine list and the chat's record and draws the answer.
public nonisolated struct CloudMoveTargetRules: Sendable {
    public init() {}

    public struct Machine: Encodable, Sendable {
        public var id: String, title: String, status: String
        public init(id: String, title: String, status: String) { (self.id, self.title, self.status) = (id, title, status) }
    }

    public struct Chat: Encodable, Sendable {
        public var offered: Bool, started: Bool, chief: Bool, running: String?, elsewhere: Bool, backHome: Bool, machines: [Machine]
        public init(offered: Bool, started: Bool, chief: Bool, running: String?, elsewhere: Bool, backHome: Bool, machines: [Machine]) {
            (self.offered, self.started, self.chief, self.running) = (offered, started, chief, running)
            (self.elsewhere, self.backHome, self.machines) = (elsewhere, backHome, machines)
        }
    }

    /// One row of Move to…: `kind` is `local` (this Mac, label empty) or `cloud`.
    public struct Target: Decodable, Equatable, Sendable {
        public var id: String, label: String, status: String?, kind: String
    }

    /// Every place the chat can move now; none when the FFI does not answer.
    public func targets(_ chat: Chat) -> [Target] {
        struct Reply: Decodable { var targets: [Target] }
        return CloudMoveCore().call("targets", chat, as: Reply.self)?.targets ?? []
    }
}
