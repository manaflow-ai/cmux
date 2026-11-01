import Foundation

/// The signed-in account's Cloud machines in the composer's environment picker, beside the peers
/// acpmux lists: a paused machine, or one the local acpmux has no link to, still shows with its
/// state, and the person can resume or open it from there. Fixed param keys (any other is
/// refused); a machine id is checked here and again by the App against the machines it loaded.
///
/// - `cloudMachine.list {}` -> `{signedIn, loaded, machines: [{id, name, stage}]}`, read-only.
///   `stage` is the machine's `CloudMachineStage` name (`ready`, `paused`, `connecting`, …);
///   `loaded` is false until the App holds a list the server answered for the account signed in.
/// - `cloudMachine.open {id}` -> `{}`: Open Machine (its first workspace; a paused one resumes).
/// - `cloudMachine.resume {id}` -> `{}`: Resume Machine, for a paused machine only.
/// - `cloudMachine.chatAccess {id}` -> the caller's server-side chat grant.
/// - `cloudMachine.shareChat {id, user}` -> the updated grant after sharing with a member.
/// - `cloudMachine.unshareChat {id, user}` -> the updated grant after removing a member.
///
/// Open and Resume start a machine: each takes the person's own click (one gesture).
public nonisolated enum AgentPaneCloudMachineRequest: Equatable, Sendable {
    case list
    case open(id: String)
    case resume(id: String)
    case chatAccess(id: String)
    case shareChat(id: String, user: String)
    case unshareChat(id: String, user: String)

    /// The methods, for ``AgentPageOps`` and ``AgentPaneRequest``.
    public static let methods: Set<String> = [
        "cloudMachine.list", "cloudMachine.open", "cloudMachine.resume",
        "cloudMachine.chatAccess", "cloudMachine.shareChat", "cloudMachine.unshareChat",
    ]
    /// Longest id the page may send back (the API's ids are far shorter).
    static let maximumIDLength = 128
    /// Most rows one list answers.
    static let maximumListed = 200

    /// The request for `method` and `params`, nil when they break the contract.
    init?(method: String, params: [String: Any]?) {
        let params = params ?? [:]
        switch method {
        case "cloudMachine.list":
            guard params.isEmpty else { return nil }
            self = .list
        case "cloudMachine.open", "cloudMachine.resume", "cloudMachine.chatAccess":
            guard Set(params.keys) == ["id"], let id = Self.machineID(params["id"]) else { return nil }
            switch method {
            case "cloudMachine.open": self = .open(id: id)
            case "cloudMachine.resume": self = .resume(id: id)
            default: self = .chatAccess(id: id)
            }
        case "cloudMachine.shareChat", "cloudMachine.unshareChat":
            guard Set(params.keys) == ["id", "user"],
                  let id = Self.machineID(params["id"]), let user = Self.memberID(params["user"]) else { return nil }
            self = method == "cloudMachine.shareChat" ? .shareChat(id: id, user: user) : .unshareChat(id: id, user: user)
        default:
            return nil
        }
    }

    /// A machine id as the page sends it back: ASCII letters, digits, `-`, `_`, `.` and `:`.
    static func machineID(_ raw: Any?) -> String? {
        guard let id = raw as? String, !id.isEmpty, id.utf8.count <= maximumIDLength,
              id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)) })
        else { return nil }
        return id
    }

    /// Team member ids use the same bounded ASCII route-segment contract as machine ids.
    static func memberID(_ raw: Any?) -> String? { machineID(raw) }

    var method: String {
        switch self {
        case .list: "cloudMachine.list"
        case .open: "cloudMachine.open"
        case .resume: "cloudMachine.resume"
        case .chatAccess: "cloudMachine.chatAccess"
        case .shareChat: "cloudMachine.shareChat"
        case .unshareChat: "cloudMachine.unshareChat"
        }
    }
}

/// The App's side of `cloudMachine.*`: App-wide, like the account it reads. CmuxNextApp sets the
/// closures on ``shared`` at launch; a test uses its own instance. Unset, every method is refused.
@MainActor
public final class AgentPaneCloudMachines {
    public static let shared = AgentPaneCloudMachines()

    /// One Cloud machine as the picker lists it.
    public struct Machine: Equatable, Sendable {
        public var id: String
        public var name: String
        /// The machine's `CloudMachineStage` name.
        public var stage: String
        public init(id: String, name: String, stage: String) {
            (self.id, self.name, self.stage) = (id, name, stage)
        }
    }

    /// The account's machines, as the App holds them now.
    public struct Inventory: Equatable, Sendable {
        public var signedIn: Bool
        public var loaded: Bool
        public var machines: [Machine]
        public init(signedIn: Bool, loaded: Bool, machines: [Machine]) {
            (self.signedIn, self.loaded, self.machines) = (signedIn, loaded, machines)
        }
    }

    public struct ChatAccess: Equatable, Sendable {
        public var machineID: String
        public var creator: String
        public var chatStart: String
        public var canShare: Bool
        public var grants: [String]

        public init(machineID: String, creator: String, chatStart: String, canShare: Bool, grants: [String]) {
            self.machineID = machineID
            self.creator = creator
            self.chatStart = chatStart
            self.canShare = canShare
            self.grants = grants
        }
    }

    public var list: (@MainActor () async -> Inventory)?
    /// Runs Open Machine on a machine of the loaded list; false when it is not one.
    public var open: (@MainActor (String) -> Bool)?
    /// Runs Resume Machine on a paused machine of the loaded list; false otherwise.
    public var resume: (@MainActor (String) -> Bool)?
    /// Reads the caller's server-side access to the machine's existing chat.
    public var chatAccess: (@MainActor (String) async throws -> ChatAccess)?
    /// Shares the existing chat with a current team member.
    public var shareChat: (@MainActor (String, String) async throws -> ChatAccess)?
    /// Removes a current team member's chat grant.
    public var unshareChat: (@MainActor (String, String) async throws -> ChatAccess)?

    init() {}
}

extension AgentPaneCloudMachineRequest {
    /// The page's reply. Open and Resume consume one gesture, and only once the App can run them.
    @MainActor
    func reply(_ machines: AgentPaneCloudMachines, gestures: AgentPaneUserGestures) async -> [String: Any] {
        switch self {
        case .list:
            guard let list = machines.list else { return AgentPaneModel.unsupported(method) }
            let inventory = await list()
            let rows: [[String: Any]] = inventory.machines.prefix(Self.maximumListed).map { ["id": $0.id, "name": $0.name, "stage": $0.stage] }
            return AgentPaneReply.success(["signedIn": inventory.signedIn, "loaded": inventory.loaded, "machines": rows] as [String: Any])
        case .open(let id): return run(machines.open, on: id, gestures: gestures)
        case .resume(let id): return run(machines.resume, on: id, gestures: gestures)
        case .chatAccess(let id): return await read(machines.chatAccess, id: id)
        case .shareChat(let id, let user): return await mutate(machines.shareChat, id: id, user: user, gestures: gestures)
        case .unshareChat(let id, let user): return await mutate(machines.unshareChat, id: id, user: user, gestures: gestures)
        }
    }

    @MainActor
    private func run(_ action: (@MainActor (String) -> Bool)?, on id: String, gestures: AgentPaneUserGestures) -> [String: Any] {
        guard let action else { return AgentPaneModel.unsupported(method) }
        guard gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        guard action(id) else { return AgentPaneReply.failure(code: "unavailable", message: "The app did not run \(method) on that Cloud machine.") }
        return AgentPaneReply.success()
    }

    @MainActor
    private func read(_ action: (@MainActor (String) async throws -> AgentPaneCloudMachines.ChatAccess)?, id: String) async -> [String: Any] {
        guard let action else { return AgentPaneModel.unsupported(method) }
        do { return AgentPaneReply.success(value(try await action(id))) }
        catch { return AgentPaneReply.failure(code: "cloud_machine_chat_failed", message: "The Cloud machine chat request failed.") }
    }

    @MainActor
    private func mutate(_ action: (@MainActor (String, String) async throws -> AgentPaneCloudMachines.ChatAccess)?, id: String, user: String,
                        gestures: AgentPaneUserGestures) async -> [String: Any] {
        guard let action else { return AgentPaneModel.unsupported(method) }
        guard gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        do { return AgentPaneReply.success(value(try await action(id, user))) }
        catch { return AgentPaneReply.failure(code: "cloud_machine_chat_failed", message: "The Cloud machine chat request failed.") }
    }

    private func value(_ access: AgentPaneCloudMachines.ChatAccess) -> [String: Any] {
        ["machineId": access.machineID, "creator": access.creator, "chatStart": access.chatStart,
         "canShare": access.canShare, "grants": access.grants]
    }
}
