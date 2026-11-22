public import Foundation
import CmuxNextWakeups

/// The Cloud machines a chat start is bringing up now, from its connect until its agent runs (prod, 2026-11-05: the
/// app's update of a just-resumed machine restarted its daemon mid-start, and the start failed "started but its
/// agent didn't (cmux-tui connection closed: EOF)"). The app's automatic machine update answers busy for such a
/// machine, so it runs after its backoff, once the agent runs; a start's own update (its daemon refused the start)
/// is not held. An update that already ran when the start came is waited out by the start.
@MainActor
public final class CloudStartGate {
    private var starts: [String: Int] = [:]

    public init() {}

    public func enter(_ machineID: String) { starts[machineID, default: 0] += 1 }

    public func leave(_ machineID: String) {
        let left = starts[machineID, default: 1] - 1
        starts[machineID] = left > 0 ? left : nil
    }

    /// Whether a start is bringing machine `machineID` up now.
    public func contains(_ machineID: String) -> Bool { starts[machineID] != nil }

    /// How long a composer start holds its machine at most (``hold(_:until:bound:clock:)``): its chat's first token
    /// ends the hold sooner. A start whose chat never answers lets the update run after this.
    public static let firstTurnBound: Duration = .seconds(300)

    /// Holds `machineID` as ``enter(_:)`` does, until ``Hold/end()``, `timeline`'s first token or `bound`, whichever
    /// comes first. A composer start holds its machine through its chat's first turn, not only its own run: the page
    /// sends the first prompt after the run returned, and an update then restarted the daemon under it (2026-11-22,
    /// cmux#45953: "cloud-chats-16 to 6dccb41ed while busy: updated" two minutes into the start; its prompt never
    /// reached the agent).
    public func hold(_ machineID: String, until timeline: CloudSendTimeline? = nil, bound: Duration = firstTurnBound,
                     clock: any Clock<Duration> = ContinuousClock()) -> Hold {
        enter(machineID)
        let hold = Hold(gate: self, machineID: machineID, timer: DemandTimer(owner: "cloud.start-gate", clock: clock))
        hold.timer.schedule(after: bound) { @MainActor [hold] in hold.end() }
        timeline?.whenFinished { Task { @MainActor [hold] in hold.end() } }
        return hold
    }

    /// One start's hold of its machine (``hold(_:bound:clock:)``); ending it twice leaves once.
    @MainActor
    public final class Hold {
        private weak var gate: CloudStartGate?
        private let machineID: String
        fileprivate let timer: DemandTimer
        public private(set) var ended = false

        fileprivate init(gate: CloudStartGate, machineID: String, timer: DemandTimer) {
            self.gate = gate
            self.machineID = machineID
            self.timer = timer
        }

        public func end() {
            guard !ended else { return }
            ended = true
            timer.cancel()
            gate?.leave(machineID)
        }
    }
}

/// A Cloud move or bring-back failure, with the action its retry can safely take.
public nonisolated struct CloudMoveFailure: Error {
    /// The failure as the toast and CLI show it.
    public let message: String
    /// What Retry does; none when retrying cannot help.
    public var retry: CloudMoveRetries.Retry?
    /// The code a Cloud start's page card reads instead of its generic failure (`seed.needs_github`: Connect GitHub); nil for that one.
    public var code: String?
    /// A Cloud start's refusal the same send may pass later, as the CLI's answer said (``CloudMoveCLI/Answer/retryable``).
    public var sendAgain = false

    /// Creates a failure without changing the chat or its retry policy.
    public init(message: String, code: String? = nil, retry: CloudMoveRetries.Retry? = nil, sendAgain: Bool = false) {
        self.message = message
        self.code = code
        self.retry = retry
        self.sendAgain = sendAgain
    }
}

/// The latest-turn Cloud fork sequence. The app supplies the small host adapters for locating
/// tabs and opening the child; this value owns the ordering and result contract.
public struct CloudTryAnotherApproach: Sendable {
    public struct Plan: Sendable {
        public let workspace: String
        public let sourceMachine: String
        public let session: String
        public let harness: String
        public let throughSeq: Int
        public let clientKey: String
        public let parentLabel: String

        public init(workspace: String, sourceMachine: String, session: String, harness: String,
                    throughSeq: Int, clientKey: String, parentLabel: String) {
            self.workspace = workspace
            self.sourceMachine = sourceMachine
            self.session = session
            self.harness = harness
            self.throughSeq = throughSeq
            self.clientKey = clientKey
            self.parentLabel = parentLabel
        }
    }

    public struct Result: Sendable {
        public let childMachine: String
        public let childSession: String
        public let childTab: String
        public let parentLabel: String
        public let throughSeq: Int
    }

    public typealias Prepare = @MainActor @Sendable (_ chat: String, _ throughSeq: Int) throws -> Plan
    public typealias ForkMachine = @MainActor @Sendable (_ plan: Plan) async throws -> CloudOwnerAPIClient.ForkRunChild
    public typealias ForkTranscript = @MainActor @Sendable (_ plan: Plan, _ childMachine: String) async throws -> String
    public typealias OpenChild = @MainActor @Sendable (_ plan: Plan, _ childMachine: String, _ session: String) async throws -> String

    private let prepare: Prepare
    private let forkMachine: ForkMachine
    private let forkTranscript: ForkTranscript
    private let openChild: OpenChild

    public init(prepare: @escaping Prepare, forkMachine: @escaping ForkMachine,
                forkTranscript: @escaping ForkTranscript, openChild: @escaping OpenChild) {
        self.prepare = prepare
        self.forkMachine = forkMachine
        self.forkTranscript = forkTranscript
        self.openChild = openChild
    }

    @MainActor
    public func run(chat: String, throughSeq: Int) async throws -> Result {
        let plan = try prepare(chat, throughSeq)
        let child = try await forkMachine(plan)
        guard let childMachine = child.machineId else {
            throw NSError(domain: "cloud.tryAnotherApproach", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cloud did not return a child machine"])
        }
        let childSession = try await forkTranscript(plan, childMachine)
        let childTab = try await openChild(plan, childMachine, childSession)
        return Result(childMachine: childMachine, childSession: childSession, childTab: childTab,
                      parentLabel: plan.parentLabel, throughSeq: throughSeq)
    }
}
