public import Foundation

/// The Cloud machines a chat start is bringing up now, from its connect until its agent runs (prod, 2026-11-05: the
/// app's update of a just-resumed machine restarted its daemon mid-start, and the start failed "started but its
/// agent didn't (cmux-tui connection closed: EOF)"). The app's automatic machine update answers busy for such a
/// machine, so it runs after its backoff, once the agent runs; a start's own update (its daemon refused the start)
/// is not held. An update that already ran when the start came is waited out by the start.
///
/// A start that leaves holds the machine ``firstTurnHold`` longer, for the chat's first turn: a fresh machine boots its
/// image's cmux-tui, older than the app's, and an update turned away during the start ran 120 s later, in the first turn,
/// so the first reply waited on the daemon restart and the reconnect (prod probe 2026-11-23T19:54Z: 194.5 s to the
/// first text, 146.8 s of it after the start; cmuxterm-hq goals/cloud-first-reply-p95.md). The update now runs after it.
@MainActor
public final class CloudStartGate {
    /// How long a machine stays held after its start's agent runs: its first turn, about the time the update's
    /// busy backoff (2, then 4 minutes) moves past it.
    public static let firstTurnHold: Duration = .seconds(180)

    private var starts: [String: Int] = [:]
    private var heldUntil: [String: ContinuousClock.Instant] = [:]
    private let now: () -> ContinuousClock.Instant

    public init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) { self.now = now }

    public func enter(_ machineID: String) { starts[machineID, default: 0] += 1 }

    public func leave(_ machineID: String) {
        let left = starts[machineID, default: 1] - 1
        starts[machineID] = left > 0 ? left : nil
    }

    /// The start on machine `machineID` got its agent running: the machine stays held through the first turn,
    /// ``firstTurnHold`` from now, after the start leaves.
    public func started(_ machineID: String) {
        let until = now() + Self.firstTurnHold
        if let held = heldUntil[machineID], held >= until { return }
        heldUntil[machineID] = until
    }

    /// Runs a start's steps on machine `machineID` inside the gate (``enter(_:)``, ``leave(_:)``), and once they succeed
    /// holds the machine through the chat's first turn (``started(_:)``): the composer's start (`cloud start-chat`), which
    /// until 2026-11-23 held nothing. A start that fails holds nothing after it.
    public func holding<T>(_ machineID: String, _ body: () async throws -> T) async throws -> T {
        enter(machineID)
        defer { leave(machineID) }
        let value = try await body()
        started(machineID)
        return value
    }

    /// Enters machine `machineID` from before its link connects (`body`: the connect and the route check), and on success
    /// keeps it entered for the start's ``holding(_:entered:_:)``, which takes it over. RED before (cmux#55519, a warm spare in
    /// a dev build, 2026-11-24): the composer's start entered only after its connect; the connect's handshake offered the
    /// automatic update, which restarted the daemon under the start, about 21 s of a 34 s start.
    public func entering<T>(_ machineID: String, _ body: () async throws -> T) async throws -> T {
        enter(machineID)
        do { return try await body() } catch { leave(machineID); throw error }
    }

    /// ``holding(_:_:)`` for a machine ``entering(_:_:)`` already entered: no gap between the two.
    public func holding<T>(_ machineID: String, entered: Bool, _ body: () async throws -> T) async throws -> T {
        guard entered else { return try await holding(machineID, body) }
        defer { leave(machineID) }
        let value = try await body()
        started(machineID)
        return value
    }

    /// Whether a start is bringing machine `machineID` up now, or its first turn runs (``firstTurnHold``).
    public func contains(_ machineID: String) -> Bool {
        if starts[machineID] != nil { return true }
        guard let until = heldUntil[machineID] else { return false }
        if now() < until { return true }
        heldUntil[machineID] = nil
        return false
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
