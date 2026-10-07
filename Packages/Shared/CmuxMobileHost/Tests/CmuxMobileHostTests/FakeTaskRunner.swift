import CmuxMobileHost
import CmuxMobileWire
import Foundation

/// An in-memory task runner: advertised agents, recorded dispatches and cancels,
/// change signals like acpmux session events.
actor FakeTaskRunner: MobileTaskRunner {
    static let claude = MobileAgent(
        id: "claude", name: "Claude Code",
        models: [MobileAgentModel(id: "opus", label: "Opus", efforts: ["low", "medium", "high"], defaultEffort: "medium"),
                 MobileAgentModel(id: "haiku", label: "Haiku")],
        defaultModel: "opus")
    static let codex = MobileAgent(id: "codex", name: "Codex", models: [MobileAgentModel(id: "gpt-5.6", label: "GPT-5.6")],
                                   unavailable: "Not signed in")

    private(set) var agentList: [MobileAgent]
    private(set) var taskList: [MobileTask] = []
    private(set) var dispatched: [(MobileTaskDispatch, MobileOpContext)] = []
    private(set) var cancelled: [String] = []
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var next = 0

    init(agents: [MobileAgent] = [FakeTaskRunner.claude, FakeTaskRunner.codex]) {
        agentList = agents
    }

    func agents() async throws -> [MobileAgent] { agentList }

    func tasks() async throws -> [MobileTask] { taskList }

    func changes() async -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[UUID()] = continuation
        return stream
    }

    func dispatch(_ request: MobileTaskDispatch, context: MobileOpContext) async throws -> MobileTaskDispatchResult {
        dispatched.append((request, context))
        next += 1
        let task = MobileTask(id: "task_k\(next)", host: "h_mac1", workspace: request.workspace ?? "ws_new\(next)",
                              tab: "tab_a\(next)", agent: request.agent, state: .queued,
                              title: String(request.prompt.prefix(40)), createdAt: Int64(1_791_331_208_000 + next))
        taskList.insert(task, at: 0)
        return MobileTaskDispatchResult(task: task.id, workspace: task.workspace ?? "", tab: task.tab ?? "")
    }

    func cancel(task: String, context: MobileOpContext) async throws {
        cancelled.append(task)
        setState(task, .failed)
    }

    func setState(_ id: String, _ state: MobileTaskState) {
        guard let index = taskList.firstIndex(where: { $0.id == id }) else { return }
        taskList[index].state = state
        signal()
    }

    func setAgents(_ agents: [MobileAgent]) {
        agentList = agents
        signal()
    }

    var dispatchCount: Int { dispatched.count }
    var lastDispatch: MobileTaskDispatch? { dispatched.last?.0 }
    var lastContext: MobileOpContext? { dispatched.last?.1 }

    private func signal() {
        for continuation in subscribers.values { continuation.yield() }
    }
}

/// Resolves uploads that belong to one install only.
struct FakeAttachments: MobileTaskAttachmentResolver {
    let install: String
    let uploads: [String: String]

    func resolve(_ ids: [String], install: String) async throws -> [MobileTaskAttachment] {
        try ids.map { id in
            guard install == self.install, let path = uploads[id] else {
                throw MobileDaemonError(code: "task.attachment_missing", message: "\(id) was not uploaded by \(install)")
            }
            return MobileTaskAttachment(upload: id, path: path)
        }
    }
}
