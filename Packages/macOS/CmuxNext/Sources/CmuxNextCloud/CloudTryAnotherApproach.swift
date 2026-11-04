import Foundation

/// The latest-turn Cloud fork sequence. The app supplies the small host adapters for locating
/// tabs and opening the child; this package owns the ordering and result contract.
public enum CloudTryAnotherApproach {
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

    @MainActor
    public static func run(chat: String, throughSeq: Int, prepare: @escaping Prepare,
                           forkMachine: @escaping ForkMachine, forkTranscript: @escaping ForkTranscript,
                           openChild: @escaping OpenChild) async throws -> Result {
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
