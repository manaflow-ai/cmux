public import CmuxNextDaemon
public import Foundation

/// A Cloud create at the plan's machine cap (leo-workspace design/cloud.md, "At the machine cap"). Leo,
/// 2026-11-02: "you try to create a new workspace/machine past the cap, what do we wanna do? reuse existing or ask
/// upgrade or".
///
/// cmux-platform's CloudDO makes room itself on the app-server link: a person's create at the cap pauses the least
/// recently used of their own idle machines, then creates, and the answer names it (`made_room`). Only when every
/// machine of theirs is busy does the create come back refused (`cloud.quota.exceeded`, `details.busy`), and the app
/// shows one card: Pause one (each busy machine), Upgrade, or Run on This Mac. The classic link makes no room (it
/// gets no new features before the DEV cutover): it shows the same card, with Pause only where pausing frees room. A
/// free plan has nothing to pause: Upgrade or Run on This Mac. Never another workspace's machine, never a teammate's.
public nonisolated struct CloudMachineCap: Equatable, Sendable {
    /// One of the person's own machines that counts against the cap.
    public struct Busy: Equatable, Sendable, Codable {
        public var machine: String
        public var name: String
        /// Its last activity, when the server knows it.
        public var lastActiveAt: Date?

        public init(machine: String, name: String, lastActiveAt: Date? = nil) {
            self.machine = machine
            self.name = name
            self.lastActiveAt = lastActiveAt
        }
    }

    /// What the person picked on the card.
    public enum Choice: Equatable, Sendable {
        /// Pause this machine, then create.
        case pause(String)
        /// The upgrade flow (cmux.com/pricing).
        case upgrade
        /// Run it on this Mac instead: nothing is created.
        case runHere
    }

    /// Thrown when the person picked Run on This Mac: the caller runs the work here instead.
    public struct RunHere: Error, Equatable, Sendable {
        public init() {}
    }

    /// The chat page's failure code for ``RunHere``: the page sends the prompt on this Mac instead (webviews cloudRun.ts).
    public static let runHereCode = "run_on_this_mac"

    /// Newest activity first; empty on a free plan.
    public var busy: [Busy]
    /// The plan has no Cloud machines at all: the card offers no pause.
    public var freePlan: Bool

    public init(busy: [Busy] = [], freePlan: Bool = false) {
        self.busy = busy
        self.freePlan = freePlan
    }

    /// The card as cmux-cloud-machine `cap.rs` answers it.
    private struct Card: Decodable {
        var busy: [Busy]
        var freePlan: Bool
    }

    /// The card for an app-server refusal at the cap (`cmux.cloud.quota_exceeded`, upstream `cloud.quota.exceeded`, its
    /// `details.busy`); nil for any other error.
    public static func refusal(_ error: any Error) -> CloudMachineCap? {
        guard let failure = error as? CloudAppOpFailure else { return nil }
        struct Request: Encodable { var code: String, details: JSONValue? }
        struct Reply: Decodable { var cap: Card? }
        let reply = CloudMachineRules().call("cloud_machine_cap_refusal", Request(code: failure.code, details: failure.details), as: Reply.self)
        return reply?.cap.map { CloudMachineCap(busy: $0.busy, freePlan: $0.freePlan) }
    }

    /// The card for a refusal the app read itself (its plan gate, the classic link's 402): `user`'s own live machines,
    /// newest activity first, only when pausing one frees what refused the create (`pauseFrees`), else no pause.
    /// The classic link's machine allowance counts paused machines too, so there only its vCPU and memory pool refusal,
    /// which counts running machines alone, offers Pause (cmux#32710). Never a teammate's machine.
    public static func plan(freePlan: Bool, pauseFrees: Bool, machines: [CloudMachine], user: String?) -> CloudMachineCap {
        struct Request: Encodable { var freePlan: Bool, pauseFrees: Bool, machines: [CloudMachine], user: String? }
        let request = Request(freePlan: freePlan, pauseFrees: pauseFrees, machines: machines, user: user)
        let card = CloudMachineRules().call("cloud_machine_cap_plan", request, as: Card.self)
        return CloudMachineCap(busy: card?.busy ?? [], freePlan: freePlan)
    }

    /// The machine a create's answer paused to make room (`made_room.machine`), nil when it paused none.
    public static func madeRoom(_ answer: JSONValue) -> JSONValue? {
        struct Request: Encodable { var answer: JSONValue }
        struct Reply: Decodable { var machine: JSONValue? }
        return CloudMachineRules().call("cloud_machine_cap_made_room", Request(answer: answer), as: Reply.self)?.machine ?? nil
    }

    /// A create at the cap. Runs `create(false)`; when `person` started it and `cap` reads a cap refusal from its
    /// error, the person picks on the card (`choose`): Pause runs `pause` on that machine, then `create(true)` once
    /// more (a new key: the first one's answer is the refusal); Run on This Mac throws ``RunHere``; Upgrade (which
    /// `choose` opened) and Not now rethrow the refusal. An agent's create gets no card.
    @MainActor public static func creating<T>(person: Bool, cap: (any Error) -> CloudMachineCap?,
                                              choose: @MainActor (CloudMachineCap) async -> Choice?,
                                              pause: @MainActor (String) async throws -> Void,
                                              create: @MainActor (_ again: Bool) async throws -> T) async throws -> T {
        do {
            return try await create(false)
        } catch {
            guard person, let found = cap(error) else { throw error }
            switch await choose(found) {
            case .pause(let machine)?:
                try await pause(machine)
                return try await create(true)
            case .runHere?: throw RunHere()
            case .upgrade?, nil: throw error
            }
        }
    }
}
