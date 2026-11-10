/// Move to…'s rules, asked of Rust (cmux-cloud-start-core `moves::targets`, with its tests): where a
/// started chat can move and which folder a machine-to-machine move copies. The app reads its
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

    public struct Folder: Decodable, Equatable, Sendable {
        /// The tree that is copied, at the same path on both machines; `chat` is inside it.
        public var root: String, chat: String
    }

    /// The folder a move from one Cloud machine to another takes; nil without an absolute one.
    public func folder(remoteFolder: String?, remoteChat: String?, cwd: String?) -> Folder? {
        struct Request: Encodable { var remoteFolder: String?, remoteChat: String?, cwd: String? }
        struct Reply: Decodable { var folder: Folder? }
        return CloudMoveCore().call("relocate_folder", Request(remoteFolder: remoteFolder, remoteChat: remoteChat, cwd: cwd), as: Reply.self)?.folder
    }
}
