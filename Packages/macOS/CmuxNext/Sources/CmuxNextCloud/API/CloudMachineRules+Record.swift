import CmuxNextDaemon
public import Foundation

/// The record's rules, each one call into cmux-cloud-machine (`rules.rs`, `cap.rs`, `limits.rs`);
/// the names are the ones the app has always called.
extension CloudMachine {
    /// Whether the machine has run at least once (a paused machine ran before it paused).
    public var hasRun: Bool { facts.hasRun }

    /// The machine is gone or going: not listed to phones.
    public var isGoneForPhones: Bool { facts.goneForPhones }

    /// This list read's record taken over `current`, the session's copy (`CloudMachineSession.listed`):
    /// a connect since the read began keeps `current`'s live status.
    public func listed(over current: CloudMachine, connectedSinceRead: Bool) -> CloudMachine {
        struct Request: Encodable { var record: CloudMachine, current: CloudMachine, connectedSinceRead: Bool }
        struct Reply: Decodable { var machine: CloudMachine }
        let request = Request(record: self, current: current, connectedSinceRead: connectedSinceRead)
        return CloudMachineRules().call("cloud_machine_listed", request, as: Reply.self)?.machine ?? self
    }

    /// What a session does when this record replaces one whose status was `previous`.
    public enum RecordEdge: String, Equatable, Sendable, Decodable { case suspend, connect, retry }

    /// This record's ``RecordEdge`` over `previous`; nil: nothing to do.
    public func edge(from previous: Status, wasResuming: Bool, connected: Bool) -> RecordEdge? {
        struct Request: Encodable { var record: CloudMachine, previous: Status, wasResuming: Bool, connected: Bool }
        struct Reply: Decodable { var edge: RecordEdge? }
        let request = Request(record: self, previous: previous, wasResuming: wasResuming, connected: connected)
        return CloudMachineRules().call("cloud_machine_edge", request, as: Reply.self)?.edge ?? nil
    }

    /// Whether a pending change holds back a connect from `origin` (`CloudMachineSession.connect`).
    public func holdsConnect(origin: CloudLinkOrigin, appLink: Bool) -> Bool {
        struct Request: Encodable { var machine: CloudMachine, origin: String, appLink: Bool }
        struct Reply: Decodable { var holds: Bool }
        let request = Request(machine: self, origin: origin.rawValue, appLink: appLink)
        return CloudMachineRules().call("cloud_machine_holds_connect", request, as: Reply.self)?.holds ?? shownStatus.isChanging
    }

    /// This machine's entry in `cmux link start-chat plan`'s `machines`.
    public func startChatPlanEntry(connected: Bool, chats: Int?) -> [String: Any] {
        struct Request: Encodable { var machine: CloudMachine, connected: Bool, chats: Int? }
        struct Reply: Decodable { var entry: JSONValue }
        let reply = CloudMachineRules().call("cloud_machine_plan_entry", Request(machine: self, connected: connected, chats: chats), as: Reply.self)
        guard let data = reply.flatMap({ try? JSONEncoder().encode($0.entry) }),
              let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ["id": id, "title": title, "status": shownStatus.rawValue, "connected": connected]
        }
        return entry
    }

    /// The name a new machine gets when the person typed none: `base` when no title in `taken`
    /// is it, else the first free `numbered(n)` from 2.
    public static func defaultName(taken: some Sequence<String>, base: String, numbered: (Int) -> String) -> String {
        let taken = Array(taken)
        let candidates = [base] + (2...(taken.count + 2)).map(numbered)
        let reply = CloudMachineRules().call("cloud_machine_default_name", DefaultNameRequest(taken: taken, candidates: candidates),
                                             as: DefaultNameReply.self)
        return reply?.name ?? base
    }
}

extension Collection<CloudMachine> {
    /// The ids of the store's machines the account's list did not name (`listed`): kept for a pin.
    public func keptForPin(listed: Set<String>) -> [String] {
        let request = KeptForPinRequest(machines: Array(self), listed: listed.sorted())
        return CloudMachineRules().call("cloud_machine_kept_for_pin", request, as: KeptForPinReply.self)?.ids ?? []
    }
}

/// The generic rules' requests and answers (file level: a generic function nests no types).
private struct DefaultNameRequest: Encodable {
    var taken: [String]
    var candidates: [String]
}

private struct DefaultNameReply: Decodable { var name: String? }

private struct KeptForPinRequest: Encodable {
    var machines: [CloudMachine]
    var listed: [String]
}

private struct KeptForPinReply: Decodable { var ids: [String] }

/// The account's machine cap, from `GET /api/vm`'s `limits` (cmux-cloud-machine `limits.rs`).
public struct CloudMachineLimits: Sendable, Hashable, Codable {
    /// Most machines that may run at once. Nil: no cap. Zero: machines are closed on this plan.
    public var maxActiveVms: Int?
    /// Machines running or starting now, as the server counts them.
    public var activeVmCount: Int
    /// The plan that sets the cap (`free`, `go`, `pro`, `max`, `team`).
    public var planId: String?
    /// The memory sizes a create on this plan may ask for, smallest first.
    public var memoryOptionsMb: [Int]
    /// The vCPUs the server gives each of those sizes.
    public var vcpusByMemoryMb: [Int: Int]
    /// Sizes the server offers only with a plan upgrade, in MiB.
    public var lockedMemoryOptionsMb: [Int]?

    public init(maxActiveVms: Int?, activeVmCount: Int, planId: String? = nil,
                memoryOptionsMb: [Int] = [], vcpusByMemoryMb: [Int: Int] = [:], lockedMemoryOptionsMb: [Int]? = nil) {
        self.maxActiveVms = maxActiveVms
        self.activeVmCount = activeVmCount
        self.planId = planId
        self.memoryOptionsMb = memoryOptionsMb
        self.vcpusByMemoryMb = vcpusByMemoryMb
        self.lockedMemoryOptionsMb = lockedMemoryOptionsMb
    }

    /// Whether the plan pays for cmux Cloud.
    public var paysForCloud: Bool {
        struct Request: Encodable { var planId: String?, maxActiveVms: Int? }
        struct Reply: Decodable { var pays: Bool }
        return CloudMachineRules().call("cloud_machine_limits_pays", Request(planId: planId, maxActiveVms: maxActiveVms), as: Reply.self)?.pays ?? false
    }
}
