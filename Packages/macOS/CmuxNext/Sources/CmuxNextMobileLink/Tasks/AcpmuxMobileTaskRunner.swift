public import CmuxMobileHost
public import CmuxMobileWire
public import Foundation

/// `MobileTaskRunner` over this Mac's acpmux and workspace store
/// (c8-composer.md 3). A dispatch makes the workspace when none is named,
/// starts `session/new {cwd: the workspace's directory, _meta.harness}` with
/// only values this Mac advertised, applies the model and effort, opens an
/// agent tab on the session, and sends the prompt as one ACP text block plus
/// a `resource_link` per resolved attachment. State follows the session:
/// `queued` until it exists, `running`, `needs_input` while an agent asks
/// for permission (the Mac's agent tab answers), `done` or `failed` when the
/// prompt turn ends. The host's spawn gate (`allowsTaskDispatch`, default
/// off) decides whether any dispatch reaches this.
public actor AcpmuxMobileTaskRunner: MobileTaskRunner {
    private struct Record {
        var task: MobileTask
        var session: String?
    }

    /// Tasks kept for the `task:` stream (the newest).
    public static let keptTasks = 50

    private let hostID: String
    private let connect: @Sendable () async throws -> any AcpmuxRPC
    private let workspaces: any MobileTaskWorkspaces
    private let now: @Sendable () -> Date
    private var rpc: (any AcpmuxRPC)?
    private var connecting: Task<any AcpmuxRPC, any Error>?
    private var records: [String: Record] = [:]
    private var order: [String] = []
    private var sinks: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var pump: Task<Void, Never>?
    private var prompts: [String: Task<Void, Never>] = [:]
    private var generation = 0

    public init(hostID: String, workspaces: any MobileTaskWorkspaces,
                now: @escaping @Sendable () -> Date = { Date() },
                connect: @escaping @Sendable () async throws -> any AcpmuxRPC) {
        self.hostID = hostID
        self.workspaces = workspaces
        self.now = now
        self.connect = connect
    }

    /// Ends the acpmux connection; running agents keep running on the Mac.
    public func close() async {
        pump?.cancel()
        pump = nil
        prompts.values.forEach { $0.cancel() }
        prompts = [:]
        await rpc?.close()
        rpc = nil
        sinks.values.forEach { $0.finish() }
        sinks = [:]
    }

    // MARK: MobileTaskRunner

    public func agents() async throws -> [MobileAgent] {
        let rpc = try await connection()
        let harnesses = try await rpc.call("_acpmux/harnesses", params: .object([:]))
        let models = try await rpc.call("_acpmux/models", params: .object([:]))
        return AcpmuxCatalog.agents(harnesses: harnesses, models: models)
    }

    public func tasks() async throws -> [MobileTask] {
        order.reversed().compactMap { records[$0]?.task }
    }

    public func changes() async -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        sinks[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.dropSink(id) } }
        return stream
    }

    public func dispatch(_ request: MobileTaskDispatch, context: MobileOpContext) async throws -> MobileTaskDispatchResult {
        let rpc = try await connection()
        let key = context.idempotencyKey
        let workspace: String
        if let named = request.workspace {
            workspace = named
        } else {
            workspace = try await mapped { try await self.workspaces.createWorkspace(idempotencyKey: "mobile-task-ws-\(key)") }
        }
        let cwd = try await mapped { try await self.workspaces.directory(of: workspace) }
        let id = "task_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(22)
        insert(Record(task: MobileTask(id: String(id), host: hostID, workspace: workspace, agent: request.agent, state: .queued,
                                       title: Self.title(request.prompt), createdAt: Self.millis(now())), session: nil))
        do {
            let created = try await rpc.call("session/new", params: .object([
                "cwd": .string(cwd), "mcpServers": .array([]), "_meta": .object(["harness": .string(request.agent)]),
            ]))
            guard let session = created["sessionId"]?.stringValue else { throw AcpmuxRPCError("session/new returned no sessionId") }
            update(String(id)) { $0.session = session }
            if let model = request.model, model != "default" {
                _ = try await rpc.call("session/set_model", params: .object(["sessionId": .string(session), "modelId": .string(model)]))
            }
            if let effort = request.effort, let option = Self.effortOption(in: created) {
                _ = try await rpc.call("session/set_config_option", params: .object([
                    "sessionId": .string(session), "configId": .string(option), "value": .string(effort),
                ]))
            }
            let tab = try await workspaces.openAgentTab(workspace: workspace, session: session, harness: request.agent,
                                                        idempotencyKey: "mobile-task-tab-\(key)")
            update(String(id)) {
                $0.task.tab = tab
                $0.task.state = .running
            }
            startPrompt(task: String(id), session: session, request: request, rpc: rpc)
            return MobileTaskDispatchResult(task: String(id), workspace: workspace, tab: tab)
        } catch {
            update(String(id)) { $0.task.state = .failed }
            throw MobileDaemonError(code: "owner.unreachable", message: "the agent did not start: \(error)", retryable: true)
        }
    }

    public func cancel(task: String, context: MobileOpContext) async throws {
        guard let record = records[task] else { throw MobileDaemonError(code: "task.not_found", message: "\(task) is not on this Mac") }
        guard let session = record.session else { return }
        try await connection().notify("session/cancel", params: .object(["sessionId": .string(session)]))
    }

    // MARK: Private

    private func connection() async throws -> any AcpmuxRPC {
        if let rpc { return rpc }
        if let connecting { return try await mapped { try await connecting.value } }
        let task = Task { try await connect() }
        connecting = task
        defer { connecting = nil }
        let made = try await mapped { try await task.value }
        if let rpc { return rpc }
        rpc = made
        generation += 1
        let current = generation
        let messages = await made.messages()
        pump = Task { [weak self] in
            for await message in messages { await self?.observe(message) }
            await self?.lost(current)
        }
        return made
    }

    /// acpmux closed: the next call connects again; running sessions keep their last state.
    private func lost(_ ended: Int) {
        guard ended == generation else { return }
        rpc = nil
    }

    private func observe(_ message: AcpmuxMessage) {
        guard let session = message.params["sessionId"]?.stringValue,
              let id = records.first(where: { $0.value.session == session })?.key else { return }
        switch message.method {
        case "session/request_permission":
            update(id) { if $0.task.state == .running { $0.task.state = .needsInput } }
        case "session/update":
            update(id) { if $0.task.state == .needsInput { $0.task.state = .running } }
        default:
            break
        }
    }

    private func startPrompt(task id: String, session: String, request: MobileTaskDispatch, rpc: any AcpmuxRPC) {
        var blocks: [JSONValue] = [.object(["type": .string("text"), "text": .string(request.prompt)])]
        for attachment in request.attachments {
            let url = URL(fileURLWithPath: attachment.path)
            blocks.append(.object(["type": .string("resource_link"), "uri": .string(url.absoluteString),
                                   "name": .string(url.lastPathComponent)]))
        }
        let params: JSONValue = .object(["sessionId": .string(session), "prompt": .array(blocks)])
        prompts[id] = Task { [weak self] in
            let state: MobileTaskState
            do {
                let reply = try await rpc.call("session/prompt", params: params)
                state = reply["stopReason"]?.stringValue == "refusal" ? .failed : .done
            } catch {
                state = .failed
            }
            await self?.finish(id, state)
        }
    }

    private func finish(_ id: String, _ state: MobileTaskState) {
        prompts[id] = nil
        update(id) { $0.task.state = state }
    }

    private func insert(_ record: Record) {
        records[record.task.id] = record
        order.append(record.task.id)
        // The oldest tasks whose turn ended leave first; a running one stays.
        while order.count > Self.keptTasks, let index = order.firstIndex(where: { prompts[$0] == nil }) {
            records[order.remove(at: index)] = nil
        }
        changed()
    }

    private func update(_ id: String, _ body: (inout Record) -> Void) {
        guard var record = records[id] else { return }
        let before = record.task
        body(&record)
        records[id] = record
        if record.task != before { changed() }
    }

    private func changed() {
        for sink in sinks.values { sink.yield() }
    }

    private func dropSink(_ id: UUID) { sinks[id] = nil }

    /// Daemon and acpmux failures in the shared error shape.
    private func mapped<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as MobileDaemonError {
            throw error
        } catch {
            throw MobileDaemonError(code: "owner.unreachable", message: String(describing: error), retryable: true)
        }
    }

    /// The session's effort option, when the harness has one (`configOptions`
    /// entry with id `effort` or category `thought_level`).
    static func effortOption(in created: JSONValue) -> String? {
        for option in created["configOptions"]?.acpmuxItems ?? [] {
            guard let id = option["id"]?.stringValue else { continue }
            if id == "effort" || option["category"]?.stringValue == "thought_level" { return id }
        }
        return nil
    }

    /// The first line of the prompt, at most 80 characters.
    static func title(_ prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }
}
