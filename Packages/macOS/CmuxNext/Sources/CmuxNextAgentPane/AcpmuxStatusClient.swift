import CmuxNextCompat
import Foundation
import Network

/// Asks a running acpmux daemon for its WebSocket endpoint over the unix
/// socket: `initialize`, then `_acpmux/status`, whose `webUrl` carries the
/// port and token. JSON-RPC 2.0, one JSON object per line. Network.framework
/// keeps every read and write off the caller's thread.
nonisolated enum AcpmuxStatusClient {
    nonisolated enum Failure: Error, Equatable {
        case unreachable(String)
        case closed
        case rpc(String)
        case noWebSocket
        /// The connected daemon did not advertise the required operation semantics.
        case unsupportedFeature(String)
        /// The daemon on the socket runs from another acpmux home (another app's or tag's).
        case otherHome(String)
        /// The socket path does not fit a Unix socket address (`sun_path`): no daemon can listen
        /// there, and `NWEndpoint.unix` traps on it.
        case socketPathTooLong(String)
    }

    /// The Network endpoint of the Unix socket `path` (``NWEndpoint/unixSocket(path:)``), or
    /// ``Failure/socketPathTooLong(_:)`` for a path that does not fit one, where `NWEndpoint.unix`
    /// traps (the page's `_acpmux/status` read with a long TMPDIR crashed the process, #28492).
    static func unixEndpoint(_ path: String) throws -> NWEndpoint {
        do { return try NWEndpoint.unixSocket(path: path) } catch { throw Failure.socketPathTooLong(error.path) }
    }

    /// The endpoint of the daemon listening on `socketPath`. Throws
    /// `.unreachable` when nothing answers there (start one then).
    @concurrent static func endpoint(socketPath: String, deadline: Duration = .seconds(2)) async throws -> AcpmuxWebEndpoint {
        try await status(socketPath: socketPath, deadline: deadline).endpoint()
    }

    /// The running daemon's `_acpmux/status`. Throws `.unreachable` when
    /// nothing answers there. `deadline` nil: waits for the answer, the daemon's close (it
    /// exited) or the caller's cancel, as a slow daemon is not a dead one.
    @concurrent static func status(socketPath: String, deadline: Duration? = .seconds(2)) async throws -> AcpmuxStatus {
        let result = try await call(socketPath: socketPath, method: "_acpmux/status", deadline: deadline)
        return AcpmuxStatus(result)
    }

    /// The peers of the daemon's `_acpmux/status`. It waits for the answer however long a loaded
    /// daemon takes (#28083); the caller's cancel ends the wait (a picker that closed).
    @concurrent static func chatPeers(socketPath: String) async throws -> [AgentChatPeer] {
        AgentChatPeer.read(try await call(socketPath: socketPath, method: "_acpmux/status", deadline: nil))
    }

    /// `_acpmux/chat_open`: the daemon's open plan for one device-wide chat
    /// (nil when the answer is not a plan this build reads).
    @concurrent static func chatOpen(socketPath: String, key: String, cwd: String? = nil,
                                     deadline: Duration = .seconds(2)) async throws -> AcpmuxChatOpenPlan? {
        var params: [String: any Sendable] = ["key": key]
        if let cwd { params["cwd"] = cwd }
        let result = try await call(socketPath: socketPath, method: "_acpmux/chat_open", params: params, deadline: deadline)
        return AcpmuxChatOpenPlan(result: result)
    }

    /// `_acpmux/chat_transcript`: the past turns of one device-wide chat, read from its own
    /// transcript (cx-khns1). The page's handshake waits on it, so the deadline is `chat_open`'s.
    @concurrent static func chatTranscript(socketPath: String, key: String,
                                           deadline: Duration = .seconds(2)) async throws -> [AgentPanePastTurn] {
        let result = try await call(socketPath: socketPath, method: "_acpmux/chat_transcript", params: ["key": key], deadline: deadline)
        return AgentPanePastTurn.turns(result: result)
    }

    /// `_acpmux/chat_fork {harness, agentSessionId, cwd}`: the fork's session id. The daemon starts
    /// the harness's ACP agent for it, so the deadline covers an agent's start.
    @concurrent static func chatFork(socketPath: String, harness: String, agentSessionId: String, cwd: String?,
                                     deadline: Duration = .seconds(45)) async throws -> String {
        var params: [String: any Sendable] = ["harness": harness, "agentSessionId": agentSessionId]
        if let cwd { params["cwd"] = cwd }
        let result = try await call(socketPath: socketPath, method: "_acpmux/chat_fork", params: params, deadline: deadline)
        guard let forked = result["agentSessionId"] as? String, !forked.isEmpty else { throw Failure.rpc("_acpmux/chat_fork returned no agentSessionId") }
        return forked
    }

    /// `_acpmux/shutdown` to the daemon of `home`: it stops; agents under agent hosts keep
    /// running for the next daemon. With `endAgents` (Quit Everything) they end, except the
    /// agents of `keepSessions`. A daemon of another acpmux home on the socket belongs to
    /// another app or tag and is never stopped: `.otherHome`.
    @concurrent static func shutdown(socketPath: String, home: URL, endAgents: Bool = false, keepSessions: [String] = [],
                                     deadline: Duration = .seconds(2)) async throws {
        let running = try await status(socketPath: socketPath, deadline: deadline)
        guard running.serves(home: home) else { throw Failure.otherHome(running.home ?? "") }
        let params: [String: any Sendable] = endAgents ? ["endAgents": true, "keepSessions": keepSessions] : [:]
        _ = try await call(socketPath: socketPath, method: "_acpmux/shutdown", params: params, deadline: deadline)
    }

    /// `_acpmux/sessions`: a page of session summaries. Callers that need the
    /// complete set use ``sessionPages`` so a large peer mirror never crosses
    /// the single-reply limit.
    @concurrent static func sessions(socketPath: String, deadline: Duration,
                                     params: [String: any Sendable] = [:], requiredCapability: String? = nil) async throws -> ResultBox {
        ResultBox(try await call(socketPath: socketPath, method: "_acpmux/sessions", params: params,
                                 deadline: deadline, limit: params["limit"] == nil ? 1 << 20 : .max,
                                 requiredCapability: requiredCapability))
    }

    /// Pages `_acpmux/sessions` with the daemon's keyset cursor. The page size
    /// is deliberately small so each reply stays bounded; callers receive no
    /// single all-sessions size failure. The daemon's cursor defines the page
    /// scope while rows may still change between requests.
    @concurrent static func sessionPages(socketPath: String, params: [String: any Sendable] = [:],
                                         pageSize: Int = 64, requiredCapability: String? = nil,
                                         deadline: Duration = .seconds(2)) async throws -> sending [[String: Any]] {
        var pageParams = params
        pageParams["limit"] = pageSize
        var cursor: String?
        var seenCursors: Set<String> = []
        var seenRows: Set<String> = []
        var rows: [[String: Any]] = []
        let end = ContinuousClock.now + deadline
        while true { // wakeup-allow: each pass awaits one bounded socket reply; EOF, error, cursor completion, or deadline ends it
            if let cursor { pageParams["cursor"] = cursor } else { pageParams.removeValue(forKey: "cursor") }
            let remaining = end - ContinuousClock.now
            guard remaining > .zero else { throw Failure.rpc("_acpmux/sessions deadline exceeded") }
            let result = try await sessions(socketPath: socketPath, deadline: remaining, params: pageParams,
                                            requiredCapability: requiredCapability).value
            guard let page = result["sessions"] as? [[String: Any]] else {
                throw Failure.rpc("_acpmux/sessions returned no sessions page")
            }
            for row in page {
                guard let id = row["sessionId"] as? String, !id.isEmpty else {
                    throw Failure.rpc("_acpmux/sessions returned a row without sessionId")
                }
                let peer = row["peer"] as? String ?? ""
                let qualified = row["qualifiedSessionId"] as? String ?? id
                let key = "\(peer)/\(qualified)"
                if seenRows.insert(key).inserted { rows.append(row) }
            }
            guard let next = (result["nextCursor"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return rows }
            guard seenCursors.insert(next).inserted else {
                throw Failure.rpc("_acpmux/sessions returned a repeated cursor")
            }
            cursor = next
        }
    }

    /// `_acpmux/resolve` for one exact mux session id. Resolve reads the local
    /// daemon's cached peer rows, so a closed chat remains addressable while its
    /// peer is offline; unlike `_acpmux/info`, it never forwards to that peer.
    @concurrent static func sessionSummary(socketPath: String, sessionId: String,
                                           deadline: Duration = .seconds(2)) async throws -> sending [String: Any]? {
        let result: [String: Any]
        do {
            result = try await call(socketPath: socketPath, method: "_acpmux/resolve",
                                    params: ["exactSessionId": true, "sessionId": sessionId],
                                    deadline: deadline, detailed: true)
        } catch let error as AcpmuxRPCError where error.code == -32002 {
            return nil
        } catch let error as AcpmuxRPCError where shouldFallbackExactResolve(error) {
            // Attached DEV daemons can be older than the app. Their resolver
            // accepts `query` but rejects the opt-in exact-session parameter;
            // query by the complete mux id and retain only an exact match.
            do {
                let fallback = try await call(socketPath: socketPath, method: "_acpmux/resolve",
                                              params: ["query": sessionId], deadline: deadline, detailed: true)
                return sessionSummary(sessionId, in: fallback)
            } catch let fallbackError as AcpmuxRPCError where shouldTreatLegacyResolveFailureAsMissing(fallbackError) {
                return nil
            }
        }
        return sessionSummary(sessionId, in: result)
    }

    static func shouldFallbackExactResolve(_ error: AcpmuxRPCError) -> Bool {
        error.code == -32601 || error.code == -32602
    }

    /// A daemon may reject both the new exact form and the legacy resolver
    /// itself. In either case the caller has no session summary to open.
    static func shouldTreatLegacyResolveFailureAsMissing(_ error: AcpmuxRPCError) -> Bool {
        error.code == -32002 || shouldFallbackExactResolve(error)
    }

    static func sessionSummary(_ sessionId: String, in result: [String: Any]) -> [String: Any]? {
        let summary = (result["session"] as? [String: Any]).flatMap { $0["sessionId"] as? String == sessionId ? $0 : nil }
            ?? (result["matches"] as? [[String: Any]])?.first { $0["sessionId"] as? String == sessionId }
        guard var summary else { return nil }
        // Legacy resolver cards name the local machine in `host`; exact cards
        // use the absence of `peer` as the local marker. Do not turn that
        // display name into a remote folder target.
        if (summary["peer"] as? String)?.isEmpty != false,
           summary["hostKind"] == nil { summary.removeValue(forKey: "host") }
        return summary
    }

    /// `_acpmux/tag {sessionId, set, remove}`: sets and removes a session's tags.
    @concurrent static func tag(socketPath: String, sessionId: String, set: [String: String], remove: [String],
                                deadline: Duration = .seconds(2)) async throws {
        _ = try await call(socketPath: socketPath, method: "_acpmux/tag",
                           params: ["sessionId": sessionId, "set": set, "remove": remove], deadline: deadline)
    }

    /// `_acpmux/markUnread {sessionId}`: marks a session unread until it is shown again.
    @concurrent static func markUnread(socketPath: String, sessionId: String, deadline: Duration = .seconds(2)) async throws {
        _ = try await call(socketPath: socketPath, method: "_acpmux/markUnread", params: ["sessionId": sessionId], deadline: deadline)
    }

    /// `_acpmux/web_modes {sessionId?, configId?, value?}` (read-only, unix socket only): the
    /// daemon's Web mode fields, its free config ids and, for a known session with a string value,
    /// whether that value keeps the session asking (the guard's own `config_value_asks`). Nil when
    /// the daemon cannot answer (no socket, no such op, an error).
    @concurrent static func webModes(socketPath: String, sessionId: String?, configId: String?, value: String?,
                                     deadline: Duration = .seconds(2)) async -> AcpmuxWebModes? {
        var params: [String: any Sendable] = [:]
        if let sessionId { params["sessionId"] = sessionId }
        if let configId { params["configId"] = configId }
        if let value { params["value"] = value }
        guard let result = try? await call(socketPath: socketPath, method: "_acpmux/web_modes", params: params, deadline: deadline),
              let fields = result["modeFields"] as? [String], let free = result["freeConfigIds"] as? [String] else { return nil }
        return AcpmuxWebModes(modeFields: Set(fields), freeConfigIds: Set(free),
                              asks: (result["session"] as? [String: Any])?["asks"] as? Bool)
    }

    /// `_acpmux/harness_enable {folder, id}` without sha256 (unix socket): the Enable harness
    /// prompt. Writes nothing. Throws the daemon's refusal (``AcpmuxRPCError``: no trusted answer,
    /// an invalid file, no such profile), or ``Failure`` when it cannot answer or the prompt is
    /// incomplete.
    @concurrent static func harnessEnablePrompt(socketPath: String, folder: String, id: String,
                                                deadline: Duration = .seconds(5)) async throws -> AgentPaneHarnessEnablePrompt {
        let result = try await call(socketPath: socketPath, method: "_acpmux/harness_enable",
                                    params: ["folder": folder, "id": id], deadline: deadline, detailed: true)
        guard let prompt = AgentPaneHarnessEnablePrompt(result: result) else { throw Failure.closed }
        return prompt
    }

    /// `initialize`, then `method`, on a fresh connection to `socketPath`. `detailed` replies
    /// with ``AcpmuxRPCError`` (the JSON-RPC code and data) instead of `.rpc(message)`.
    /// With `requiredFeature`, no operation is sent before that connection advertises it.
    /// `deadline` nil: the call ends at the answer, at the daemon's close of the connection (a
    /// daemon that exited) or at the caller's cancel; no timer decides it.
    static func call(socketPath: String, method: String, params: [String: any Sendable] = [:],
                     deadline: Duration?, detailed: Bool = false, limit: Int = 1 << 20,
                     requiredFeature: String? = nil, requiredCapability: String? = nil) async throws -> [String: Any] {
        let connection = NWConnection(to: try unixEndpoint(socketPath), using: .tcp)
        defer { connection.cancel() }
        let operation: @Sendable () async throws -> ResultBox = {
            ResultBox(try await exchange(method, params: params, transport: AcpmuxSocketTransport(connection: connection),
                                         detailed: detailed, limit: limit, requiredFeature: requiredFeature,
                                         requiredCapability: requiredCapability))
        }
        guard let deadline else {
            // A cancelled connection fails its pending start, send and receive.
            return try await withTaskCancellationHandler(operation: operation, onCancel: { connection.cancel() }).value
        }
        let box = try await withAgentPaneDeadline(deadline, label: "acpmux \(method)", onTimeout: { connection.cancel() }, operation)
        return box.value
    }

    /// The folder of the daemon's exact `sessionId` summary, nil when the
    /// daemon has no such session or names no folder. The agent pane's commits
    /// and pushes run here, never in a folder the page names.
    @concurrent static func sessionFolder(socketPath: String, sessionId: String,
                                          deadline: Duration = .seconds(5)) async throws -> AgentPaneSessionFolder? {
        guard let result = try await sessionSummary(socketPath: socketPath, sessionId: sessionId, deadline: deadline) else { return nil }
        return AgentPaneSessionFolder(sessionId: sessionId, info: result)
    }

    /// `initialize`, then `method`; feature-dependent operations wait for
    /// the handshake on this same transport before sending their request.
    static func exchange(_ method: String, params: [String: any Sendable], transport: any AcpmuxRPCTransport,
                         detailed: Bool = false, limit: Int = 1 << 20,
                         requiredFeature: String? = nil, requiredCapability: String? = nil) async throws -> [String: Any] {
        try await transport.start()
        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": 1, "clientInfo": ["name": "cmux-next-agent-pane", "version": "1"], "clientCapabilities": [:]],
        ]
        let status: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": method, "params": params]
        let request = try JSONSerialization.data(withJSONObject: status) + Data([0x0A])
        var payload = try JSONSerialization.data(withJSONObject: initialize) + Data([0x0A])
        if requiredFeature == nil && requiredCapability == nil { payload += request }
        try await transport.send(payload)
        var initialized = false
        var buffer = Data()
        // Notifications never satisfy the handshake or the operation.
        while true {  // wakeup-allow: each pass awaits socket data; EOF, error or the deadline ends it
            guard let chunk = try await transport.receive() else { throw Failure.closed }
            buffer += chunk
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                guard line.count <= limit else { throw Failure.rpc("\(method) reply too large") }
                let frame = Data(line)
                buffer.removeSubrange(buffer.startIndex...newline)
                if (requiredFeature != nil || requiredCapability != nil), !initialized {
                    if let hello = try detailedReply(to: 1, in: frame) {
                        let meta = (hello["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
                        if let requiredFeature, (meta?["features"] as? [String])?.contains(requiredFeature) != true {
                            throw Failure.unsupportedFeature(requiredFeature)
                        }
                        if let requiredCapability, (meta?["capabilities"] as? [String])?.contains(requiredCapability) != true {
                            throw Failure.unsupportedFeature(requiredCapability)
                        }
                        try Task.checkCancellation()
                        try await transport.send(request)
                        initialized = true
                    }
                    continue
                }
                let parsed = detailed ? try detailedReply(to: 2, in: frame) : try reply(to: 2, in: frame)
                if let parsed { return parsed }
            }
            if buffer.count > limit { throw Failure.rpc("\(method) reply too large") }
        }
    }

    /// The `result` of the reply to `id` in `line`, nil for any other message.
    static func reply(to id: Int, in line: Data) throws -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (object["id"] as? NSNumber)?.intValue == id else { return nil }
        if let error = object["error"] as? [String: Any] {
            throw Failure.rpc(error["message"] as? String ?? "acpmux request failed")
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    /// `reply(to:in:)` that keeps the error's JSON-RPC code and data (``AcpmuxRPCError``).
    static func detailedReply(to id: Int, in line: Data) throws -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (object["id"] as? NSNumber)?.intValue == id else { return nil }
        if let error = object["error"] as? [String: Any] { throw AcpmuxRPCError(error) }
        return object["result"] as? [String: Any] ?? [:]
    }

    static func start(_ connection: NWConnection) async throws {
        // A caller cancelled before the connection starts has already torn it down
        // (withAgentPaneDeadline's onTimeout): a cancelled connection may never report a state.
        try Task.checkCancellation()
        let gate = AgentPaneResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    gate.run { continuation.resume(throwing: Failure.unreachable("\(error)")) }
                case .cancelled:
                    gate.run { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "cmux.next.agent-pane.acpmux-status"))
            // A cancel that landed after the check above, before the handler was in place, tore the
            // connection down where no handler saw it: answer it here. A later one reaches the
            // handler as `.cancelled`. The task's flag is set before its teardown runs, so one of
            // the two always sees it.
            if Task.isCancelled { gate.run { continuation.resume(throwing: CancellationError()) } }
        }
    }

    static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    static func receive(on connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: nil)  // EOF
                }
            }
        }
    }
}

/// A JSON result handed across the deadline boundary.
nonisolated struct ResultBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

/// The fields of `_acpmux/status` the app reads.
nonisolated struct AcpmuxStatus: Sendable, Equatable {
    var capabilities: Set<String>
    var webURL: String?
    var build: String?
    var pid: Int32?
    /// The daemon runs agents under agent hosts: a restart keeps them.
    var agentHosts: Bool
    /// The daemon keeps its chats on disk (`store.mode` `local`, the default of every build): a
    /// daemon without agent hosts that restarts resumes them from there. False for a memory store,
    /// and for a status that does not say.
    var chatsOnDisk: Bool
    /// `ACPMUX_CHIEF_MUX_HOME` of the daemon's own environment (acpmux
    /// `config/chief_builtins.rs`); nil when unset or from an older daemon.
    var chiefMuxHome: String?
    /// The daemon's `ACPMUX_HOME`; nil from a daemon that does not report it.
    var home: String?
    /// The daemon's agent launch policy (`agentLaunch`, acpmux `launch_policy.rs`): `deny` when
    /// its environment turned launches off; nil from a daemon that does not report it.
    var agentLaunch: String?

    init(webURL: String? = nil, build: String? = nil, pid: Int32? = nil, capabilities: Set<String> = [], agentHosts: Bool = false, chatsOnDisk: Bool = false,
         chiefMuxHome: String? = nil, home: String? = nil, agentLaunch: String? = nil) {
        self.capabilities = capabilities
        self.webURL = webURL
        self.build = build
        self.pid = pid
        self.agentHosts = agentHosts
        self.chatsOnDisk = chatsOnDisk
        self.chiefMuxHome = chiefMuxHome
        self.home = home
        self.agentLaunch = agentLaunch
    }

    init(_ result: [String: Any]) {
        webURL = result["webUrl"] as? String
        build = result["build"] as? String
        pid = (result["pid"] as? NSNumber).map { Int32(truncating: $0) }
        capabilities = Set(result["capabilities"] as? [String] ?? [])
        agentHosts = (result["agentHosts"] as? Bool) ?? false
        chatsOnDisk = ((result["store"] as? [String: Any])?["mode"] as? String) == "local"
        chiefMuxHome = result["chiefMuxHome"] as? String
        home = result["home"] as? String
        agentLaunch = result["agentLaunch"] as? String
    }

    /// Whether the daemon runs from `home`. One of another home on this app's socket (an
    /// inherited or mistyped `ACPMUX_SOCKET`) is another app's or tag's: never hand it off,
    /// stop it or use it. A daemon that does not report its home is taken at its socket's word.
    func serves(home expected: URL) -> Bool {
        guard let home, !home.isEmpty else { return true }
        func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        return canonical(URL(fileURLWithPath: home, isDirectory: true)) == canonical(expected)
    }

    /// The WebSocket endpoint; `.noWebSocket` when the listener failed to bind.
    func endpoint() throws -> AcpmuxWebEndpoint {
        guard let webURL, let endpoint = AcpmuxWebEndpoint(webURL: webURL) else {
            throw AcpmuxStatusClient.Failure.noWebSocket
        }
        return endpoint
    }
}
