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
///
/// Open and Resume start a machine: each takes the person's own click (one gesture).
public nonisolated enum AgentPaneCloudMachineRequest: Equatable, Sendable {
    case list
    case open(id: String)
    case resume(id: String)

    /// The methods, for ``AgentPageOps`` and ``AgentPaneRequest``.
    public static let methods: Set<String> = ["cloudMachine.list", "cloudMachine.open", "cloudMachine.resume"]
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
        case "cloudMachine.open", "cloudMachine.resume":
            guard Set(params.keys) == ["id"], let id = Self.machineID(params["id"]) else { return nil }
            self = method == "cloudMachine.open" ? .open(id: id) : .resume(id: id)
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

    var method: String {
        switch self {
        case .list: "cloudMachine.list"
        case .open: "cloudMachine.open"
        case .resume: "cloudMachine.resume"
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

    public var list: (@MainActor () async -> Inventory)?
    /// Runs Open Machine on a machine of the loaded list; false when it is not one.
    public var open: (@MainActor (String) -> Bool)?
    /// Runs Resume Machine on a paused machine of the loaded list; false otherwise.
    public var resume: (@MainActor (String) -> Bool)?

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
        }
    }

    @MainActor
    private func run(_ action: (@MainActor (String) -> Bool)?, on id: String, gestures: AgentPaneUserGestures) -> [String: Any] {
        guard let action else { return AgentPaneModel.unsupported(method) }
        guard gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        guard action(id) else { return AgentPaneReply.failure(code: "unavailable", message: "The app did not run \(method) on that Cloud machine.") }
        return AgentPaneReply.success()
    }
}
