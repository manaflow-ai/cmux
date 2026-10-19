public import CMUXMobileCore
public import CmuxAgentChat
public import CmuxMobileRPC
public import CmuxMobileShellModel
public import Foundation

private actor MobileArtifactDownloadByteCounter {
    private var storedValue = 0

    func add(_ byteCount: Int) {
        storedValue += byteCount
    }

    var value: Int {
        storedValue
    }
}

private enum MobileChatAttachmentError: Error, Sendable {
    case invalidResponse
}

/// The iOS implementation of ``CmuxAgentChat/ChatEventSource``: adapts the
/// mobile RPC client to the chat domain seam.
///
/// History and actions go through `mobile.chat.*` request methods; live
/// updates arrive on the `chat.message` event topic, filtered per session.
/// The returned event stream finishes when the underlying connection drops;
/// consumers resubscribe when they rebuild a source for a new connection.
public actor MobileChatEventSource: AgentChatSessionSource {
    private let client: MobileCoreRPCClient
    let diagnosticLog: DiagnosticLog?
    private let coding = ChatWireCoding()
    private var controlsBySession: [String: ChatSessionControls] = [:]
    public nonisolated let supportsArtifacts: Bool
    /// Whether the connected Mac supports recursive chat folder browsing.
    public nonisolated let supportsArtifactFolders: Bool
    /// Whether the connected Mac supports terminal-scoped directory listing.
    public nonisolated let supportsTerminalArtifactList: Bool
    /// Whether the connected Mac supports lifecycle-bound panel file reads.
    public nonisolated let supportsPanelArtifacts: Bool
    /// Whether the connected Mac supports session-wide artifact gallery pages.
    public nonisolated let supportsArtifactGallery: Bool
    /// Whether raw artifact bytes may use a peer-bound Iroh application lane.
    public nonisolated let supportsArtifactLane: Bool

    /// Creates the adapter.
    ///
    /// - Parameter client: The connected RPC client for the paired Mac.
    public init(
        client: MobileCoreRPCClient,
        supportsArtifacts: Bool = false,
        supportsArtifactGallery: Bool = false,
        supportsArtifactFolders: Bool = false,
        supportsTerminalArtifactList: Bool = false,
        supportsPanelArtifacts: Bool = false,
        supportsArtifactLane: Bool = false,
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.client = client
        self.diagnosticLog = diagnosticLog
        self.supportsArtifacts = supportsArtifacts
        self.supportsArtifactGallery = supportsArtifactGallery
        self.supportsArtifactFolders = supportsArtifactFolders
        self.supportsTerminalArtifactList = supportsTerminalArtifactList
        self.supportsPanelArtifacts = supportsPanelArtifacts
        self.supportsArtifactLane = supportsArtifactLane
    }

    /// Lists chat-capable agent sessions the Mac knows about.
    ///
    /// Not part of ``CmuxAgentChat/ChatEventSource`` (which is scoped to one
    /// conversation); hosts call this to build the session list.
    ///
    /// - Parameter workspaceID: Restrict to one workspace, or `nil` for all.
    /// - Returns: Sessions ordered by the host (most recent activity first).
    public func sessions(workspaceID: String?) async throws -> [ChatSessionDescriptor] {
        var params: [String: Any] = [:]
        if let workspaceID {
            params["workspace_id"] = workspaceID
        }
        let request = try MobileCoreRPCClient.requestData(method: "mobile.chat.sessions", params: params)
        let result = try await client.sendRequest(request)
        return try coding.decode(MobileChatSessionsResponse.self, from: result).sessions
    }

    /// Pulls the authoritative snapshot of one session by id.
    ///
    /// The client's reconcile path: on (re)connect, foreground, a detected
    /// version gap, or manual refresh, the host fetches the current descriptor
    /// and folds it through the same version-gated upsert as a push, so a pull
    /// that races a newer push converges. Pull is authoritative; push is a
    /// best-effort hint, so a missed or out-of-order push self-heals here.
    ///
    /// Not part of ``CmuxAgentChat/ChatEventSource`` (which is scoped to one
    /// conversation). Throws when the host no longer knows the session (treat
    /// as gone) or the request fails.
    ///
    /// - Parameter sessionID: The session to snapshot.
    /// - Returns: The session's current descriptor, with its `version`.
    public func session(sessionID: String) async throws -> ChatSessionDescriptor {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.chat.session",
            params: ["session_id": sessionID]
        )
        let result = try await client.sendRequest(request)
        return try coding.decode(MobileChatSessionResponse.self, from: result).session
    }

    public func rename(sessionID: String, title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentChatSessionActionError.invalidResponse }
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.chat.rename",
            params: ["session_id": sessionID, "title": trimmed]
        )
        _ = try await client.sendRequest(request)
    }

    public func delete(sessionID: String) async throws {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.chat.delete",
            params: ["session_id": sessionID]
        )
        _ = try await client.sendRequest(request)
    }

    public func exportTranscript(sessionID: String) async throws -> String {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.chat.export",
            params: ["session_id": sessionID]
        )
        let result = try await client.sendRequest(request)
        guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let text = object["text"] as? String else {
            throw AgentChatSessionActionError.invalidResponse
        }
        return text
    }

    public func fork(sessionID: String) async throws -> ChatSessionLaunchResult {
        try await launchSession(method: "mobile.chat.fork", sessionID: sessionID)
    }

    public func resume(sessionID: String) async throws -> ChatSessionLaunchResult {
        try await launchSession(method: "mobile.chat.resume", sessionID: sessionID)
    }

    public func reopen(sessionID: String) async throws -> ChatSessionLaunchResult {
        try await launchSession(method: "mobile.chat.reopen", sessionID: sessionID)
    }

    private func launchSession(
        method: String,
        sessionID: String
    ) async throws -> ChatSessionLaunchResult {
        let request = try MobileCoreRPCClient.requestData(
            method: method,
            params: ["session_id": sessionID]
        )
        let result = try await client.sendRequest(request)
        return try coding.decode(ChatSessionLaunchResult.self, from: result)
    }

    /// Opens the live stream of session-list events for every session the
    /// Mac knows about (not scoped to one conversation).
    ///
    /// Yields each `chat.message` frame whole, so a host can fold
    /// `descriptorChanged`/`stateChanged` into its session list (and keep
    /// the GUI toggle current) without polling. A newly-started agent emits
    /// `descriptorChanged`, so the list gains it live. The stream finishes
    /// when the connection drops; callers re-subscribe after reconnect.
    ///
    /// - Returns: Live session frames, in delivery order.
    public func sessionEvents() async -> AsyncStream<ChatSessionEventFrame> {
        let envelopes = await client.subscribe(to: ["chat.message"])
        let client = self.client
        let coding = self.coding
        let streamID = UUID().uuidString
        // Complete the server-side registration before handing the stream to
        // the reducer. This makes the subsequent authoritative session
        // snapshot race-free: events emitted after the snapshot starts are
        // already queued in `envelopes` instead of falling into a handshake
        // gap.
        do {
            let subscribe = try MobileCoreRPCClient.requestData(
                method: "mobile.events.subscribe",
                params: [
                    "topics": ["chat.message"],
                    "stream_id": streamID,
                ]
            )
            _ = try await client.sendRequest(subscribe)
        } catch {
            return AsyncStream { continuation in continuation.finish() }
        }
        return AsyncStream { continuation in
            let pump = Task {
                for await envelope in envelopes {
                    guard let payload = envelope.payloadJSON else { continue }
                    guard let frame = try? coding.decode(ChatSessionEventFrame.self, from: payload) else {
                        continue
                    }
                    continuation.yield(frame)
                }
                continuation.finish()
            }
            continuation.onTermination = { reason in
                pump.cancel()
                // Withdraw the registration only on consumer cancellation; a
                // `.finished` means the connection died and an unsubscribe
                // would reopen a torn-down transport (see `events`).
                guard case .cancelled = reason else { return }
                Task {
                    if let unsubscribe = try? MobileCoreRPCClient.requestData(
                        method: "mobile.events.unsubscribe",
                        params: ["stream_id": streamID]
                    ) {
                        _ = try? await client.sendRequest(unsubscribe)
                    }
                }
            }
        }
    }

    public func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage {
        var params: [String: Any] = [
            "session_id": sessionID,
            "limit": limit,
        ]
        if let beforeSeq {
            params["before_seq"] = beforeSeq
        }
        let request = try MobileCoreRPCClient.requestData(method: "mobile.chat.history", params: params)
        let result = try await client.sendRequest(request)
        return try coding.decode(ChatHistoryPage.self, from: result)
    }

    public func events(sessionID: String) async -> AsyncStream<ChatSessionEvent> {
        let envelopes = await client.subscribe(to: ["chat.message"])
        let client = self.client
        let coding = self.coding
        let streamID = UUID().uuidString
        do {
            let subscribe = try MobileCoreRPCClient.requestData(
                method: "mobile.events.subscribe",
                params: [
                    "topics": ["chat.message"],
                    "stream_id": streamID,
                ]
            )
            _ = try await client.sendRequest(subscribe)
        } catch {
            return AsyncStream { continuation in continuation.finish() }
        }
        return AsyncStream { continuation in
            let pump = Task {
                for await envelope in envelopes {
                    guard let payload = envelope.payloadJSON else { continue }
                    guard let frame = try? coding.decode(ChatSessionEventFrame.self, from: payload) else {
                        continue
                    }
                    guard frame.sessionID == sessionID else { continue }
                    continuation.yield(frame.event)
                }
                continuation.finish()
            }
            continuation.onTermination = { reason in
                pump.cancel()
                // Withdraw the server-side registration only when the
                // CONSUMER cancelled a live stream (chat closed). A
                // `.finished` termination means the connection itself died
                // (or the handshake failed); sending an unsubscribe there
                // would reopen a torn-down transport just to clean up a
                // registration that died with it.
                guard case .cancelled = reason else { return }
                Task {
                    if let unsubscribe = try? MobileCoreRPCClient.requestData(
                        method: "mobile.events.unsubscribe",
                        params: ["stream_id": streamID]
                    ) {
                        _ = try? await client.sendRequest(unsubscribe)
                    }
                }
            }
        }
    }

    public func send(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws {
        var params: [String: Any] = [
            "session_id": sessionID,
            "text": text,
        ]
        if !attachments.isEmpty {
            var wireAttachments: [[String: Any]] = []
            wireAttachments.reserveCapacity(attachments.count)
            for attachment in attachments {
                try Task.checkCancellation()
                if attachment.format == .file {
                    let path = try await uploadFileAttachment(attachment)
                    wireAttachments.append([
                        "kind": "file",
                        "path": path,
                    ])
                } else {
                    wireAttachments.append([
                        "kind": "image",
                        "data_b64": attachment.data.base64EncodedString(),
                        "format": attachment.format.rawValue,
                    ])
                }
            }
            params["attachments"] = wireAttachments
        }
        let request = try MobileCoreRPCClient.requestData(method: "mobile.chat.send", params: params)
        _ = try await client.sendRequest(request)
    }

    public func controls(sessionID: String) async throws -> ChatSessionControls {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.chat.controls",
            params: ["session_id": sessionID]
        )
        let result = try await client.sendRequest(request)
        let controls = try coding.decode(ChatSessionControlsResponse.self, from: result).controls
        controlsBySession[sessionID] = controls
        return controls
    }

    public func updateControls(
        _ controls: ChatSessionControls,
        sessionID: String
    ) async throws -> ChatSessionControls {
        var params: [String: Any] = ["session_id": sessionID]
        // Send explicit nulls for cleared optional controls. Omitting a key is
        // a partial update and must preserve the host's current value; null is
        // the wire-level clear operation.
        params["model_id"] = controls.modelID ?? NSNull()
        params["reasoning_effort_id"] = controls.reasoningEffortID ?? NSNull()
        params["permission_mode"] = controls.permissionMode ?? NSNull()
        params["sandbox_mode"] = controls.sandboxMode ?? NSNull()
        params["plan_mode"] = controls.planMode
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.chat.controls.update",
            params: params
        )
        let result = try await client.sendRequest(request)
        let acknowledged = try coding.decode(ChatSessionControlsResponse.self, from: result).controls
        controlsBySession[sessionID] = acknowledged
        return acknowledged
    }

    /// Uploads a general file through the same resumable host store used by
    /// the task composer. The returned path is then injected into the agent's
    /// terminal by `mobile.chat.send`, so PDFs, audio, and documents follow
    /// the same reference-by-path behavior as images.
    private func uploadFileAttachment(_ attachment: ChatOutboundAttachment) async throws -> String {
        let operationID = UUID().uuidString
        let uploadID = UUID().uuidString
        let plan = MobileTaskAttachmentChunkPlan(totalByteCount: attachment.data.count)
        var finalPath: String?
        for (index, range) in plan.ranges.enumerated() {
            try Task.checkCancellation()
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.task.attachment.upload",
                params: [
                    "operation_id": operationID,
                    "upload_id": uploadID,
                    "file_name": attachment.fileName ?? "attachment",
                    "total_bytes": attachment.data.count,
                    "offset": range.lowerBound,
                    "data_b64": attachment.data.subdata(in: range).base64EncodedString(),
                    "last": index == plan.ranges.count - 1,
                ]
            )
            let response = try await client.sendRequest(request)
            guard index == plan.ranges.count - 1 else { continue }
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let path = object["path"] as? String,
                  path.hasPrefix("/") else {
                throw MobileChatAttachmentError.invalidResponse
            }
            finalPath = path
        }
        guard let finalPath else { throw MobileChatAttachmentError.invalidResponse }
        return finalPath
    }

    public func interrupt(sessionID: String, hard: Bool) async throws {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.chat.interrupt",
            params: [
                "session_id": sessionID,
                "hard": hard,
            ]
        )
        _ = try await client.sendRequest(request)
    }

    public func answer(optionIndex: Int, sessionID: String) async throws {
        try await answer(optionIndex: optionIndex, requestID: nil, sessionID: sessionID)
    }

    public func answer(optionIndex: Int, requestID: String?, sessionID: String) async throws {
        var params: [String: Any] = [
            "session_id": sessionID,
            "option_index": optionIndex,
        ]
        if let requestID { params["request_id"] = requestID }
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.chat.answer",
            params: params
        )
        _ = try await client.sendRequest(request)
    }

    public func answer(optionIndexes: [Int], requestID: String?, sessionID: String) async throws {
        guard !optionIndexes.isEmpty else { throw AgentChatSessionActionError.unsupported }
        var params: [String: Any] = [
            "session_id": sessionID,
            "option_indexes": optionIndexes,
        ]
        if optionIndexes.count == 1, let optionIndex = optionIndexes.first {
            // Keep the legacy scalar on the wire for older hosts and test
            // fixtures; newer hosts prefer the batch field.
            params["option_index"] = optionIndex
        }
        if let requestID { params["request_id"] = requestID }
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.chat.answer",
            params: params
        )
        _ = try await client.sendRequest(request)
    }

    public func answer(text: String, requestID: String?, sessionID: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentChatSessionActionError.unsupported
        }
        var params: [String: Any] = [
            "session_id": sessionID,
            "text": text,
        ]
        if let requestID { params["request_id"] = requestID }
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.chat.answer",
            params: params
        )
        _ = try await client.sendRequest(request)
    }

    public func review(
        action: ChatReviewAction,
        sessionID: String,
        messageID: String,
        filePath: String,
        unifiedDiff: String?,
        lineNumber: Int?,
        comment: String?
    ) async throws {
        var params: [String: Any] = [
            "action": action.rawValue,
            "session_id": sessionID,
            "message_id": messageID,
            "file_path": filePath,
        ]
        if let unifiedDiff { params["unified_diff"] = unifiedDiff }
        if let lineNumber { params["line_number"] = lineNumber }
        if let comment { params["comment"] = comment }
        let request = try MobileCoreRPCClient.requestData(method: "mobile.chat.review", params: params)
        _ = try await client.sendRequest(request)
    }

    public func artifactStat(sessionID: String, path: String) async throws -> ChatArtifactStat {
        try await artifactCall(
            method: "mobile.chat.artifact.stat",
            params: [
                "session_id": sessionID,
                "path": path,
            ]
        )
    }

    public func artifactFetch(
        sessionID: String,
        path: String,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?
    ) async throws -> Data {
        try await performArtifactDownload(correlationID: sessionID) {
            try await fetchArtifactChunks(
                method: "mobile.chat.artifact.fetch",
                stringParams: ["session_id": sessionID, "path": path],
                collectsData: true,
                progress: progress,
                onChunk: { _ in }
            )
        }
    }

    public func artifactFetch(
        sessionID: String,
        path: String,
        onChunk: @Sendable (ChatArtifactChunk) async throws -> Void
    ) async throws {
        let byteCounter = MobileArtifactDownloadByteCounter()
        _ = try await performArtifactDownload(
            correlationID: sessionID,
            successByteCount: { _ in await byteCounter.value }
        ) {
            try await fetchArtifactChunks(
                method: "mobile.chat.artifact.fetch",
                stringParams: ["session_id": sessionID, "path": path],
                collectsData: false,
                progress: nil,
                onChunk: { chunk in
                    await byteCounter.add(chunk.data.count)
                    try await onChunk(chunk)
                }
            )
        }
    }

    public func artifactThumbnail(
        sessionID: String,
        path: String,
        maxDimension: Int
    ) async throws -> ChatArtifactThumbnail {
        try await artifactCall(
            method: "mobile.chat.artifact.thumbnail",
            params: [
                "session_id": sessionID,
                "path": path,
                "max_dimension": maxDimension,
            ]
        )
    }

    public func artifactList(sessionID: String, path: String) async throws -> ChatArtifactDirectoryListing {
        let startedAt = Date()
        recordAppEvent(.artifactListLoadStarted, correlationID: sessionID)
        guard supportsArtifactFolders else {
            recordAppEvent(
                .artifactListLoadFailed,
                correlationID: sessionID,
                startedAt: startedAt,
                failure: .policyUnavailable
            )
            throw ChatArtifactError.unsupported
        }
        do {
            let listing: ChatArtifactDirectoryListing = try await artifactCall(
                method: "mobile.chat.artifact.list",
                params: [
                    "session_id": sessionID,
                    "path": path,
                ]
            )
            recordAppEvent(
                .artifactListLoadSucceeded,
                correlationID: sessionID,
                startedAt: startedAt,
                count: listing.entries.count
            )
            return listing
        } catch {
            recordAppEvent(
                .artifactListLoadFailed,
                correlationID: sessionID,
                startedAt: startedAt,
                failure: DiagnosticFailureKind.classify(error)
            )
            throw error
        }
    }

    /// Fetches one stable page of the session-wide artifact gallery.
    ///
    /// - Parameters:
    ///   - sessionID: Session whose transcript authorizes the gallery universe.
    ///   - cursor: Opaque append-only cursor, or `nil` for a fresh snapshot.
    ///   - pageSize: Requested page size; the Mac clamps it to 100.
    ///   - query: Optional whole-session basename/path substring search.
    /// - Returns: A sectioned first page or flat search page.
    public func chatArtifactGallery(
        sessionID: String,
        cursor: String? = nil,
        pageSize: Int = 60,
        query: String? = nil
    ) async throws -> ChatArtifactGalleryPage {
        let startedAt = Date()
        recordAppEvent(.artifactListLoadStarted, correlationID: sessionID)
        var params: [String: Any] = [
            "session_id": sessionID,
            "page_size": pageSize,
        ]
        if let cursor {
            params["cursor"] = cursor
        }
        if let query, !query.isEmpty {
            params["query"] = query
        }
        if supportsArtifactFolders {
            params["include_directories"] = true
        }
        do {
            let page: ChatArtifactGalleryPage = try await artifactCall(
                method: "mobile.chat.artifact.gallery",
                params: params
            )
            let filtered = supportsArtifactFolders ? page : page.excludingDirectories()
            recordAppEvent(
                .artifactListLoadSucceeded,
                correlationID: sessionID,
                startedAt: startedAt,
                count: filtered.created.count
                    + filtered.attached.count
                    + filtered.referenced.count
            )
            return filtered
        } catch {
            recordAppEvent(
                .artifactListLoadFailed,
                correlationID: sessionID,
                startedAt: startedAt,
                failure: DiagnosticFailureKind.classify(error)
            )
            throw error
        }
    }

    func performArtifactDownload(
        correlationID: String,
        successByteCount: @Sendable (Data) async -> Int = { $0.count },
        operation: () async throws -> Data
    ) async throws -> Data {
        let startedAt = Date()
        recordAppEvent(.artifactDownloadStarted, correlationID: correlationID)
        do {
            let data = try await operation()
            recordAppEvent(
                .artifactDownloadSucceeded,
                correlationID: correlationID,
                startedAt: startedAt,
                count: await successByteCount(data)
            )
            return data
        } catch {
            recordAppEvent(
                .artifactDownloadFailed,
                correlationID: correlationID,
                startedAt: startedAt,
                failure: DiagnosticFailureKind.classify(error)
            )
            throw error
        }
    }

    func recordAppEvent(
        _ kind: DiagnosticAppEventKind,
        correlationID: String? = nil,
        startedAt: Date? = nil,
        failure: DiagnosticFailureKind? = nil,
        count: Int? = nil
    ) {
        let elapsedMilliseconds = startedAt.map {
            UInt32(clamping: Int(max(0, Date().timeIntervalSince($0)) * 1_000))
        }
        diagnosticLog?.recordAppEvent(
            kind,
            correlationID: correlationID,
            elapsedMilliseconds: elapsedMilliseconds,
            failure: failure,
            count: count
        )
    }

    func artifactCall<T: Decodable>(
        method: String,
        params: [String: Any]
    ) async throws -> T {
        do {
            let request = try MobileCoreRPCClient.requestData(method: method, params: params)
            let result = try await client.sendRequest(request)
            return try coding.decode(T.self, from: result)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MobileArtifactFailureClassifier().classify(error, method: method)
        }
    }

    func fetchArtifactChunks(
        method: String,
        stringParams: [String: String],
        collectsData: Bool,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?,
        onChunk: @Sendable (ChatArtifactChunk) async throws -> Void
    ) async throws -> Data {
        if supportsArtifactLane {
            let descriptor: ChatArtifactLaneDescriptor
            let connection: any MobileArtifactLaneConnection
            do {
                var descriptorParams: [String: Any] = stringParams
                descriptorParams["transport"] = "iroh_artifact_v1"
                descriptor = try await artifactCall(
                    method: method,
                    params: descriptorParams
                )
                guard descriptor.totalSize >= 0 else {
                    throw MobileArtifactLaneFetchError.invalidDescriptor
                }
                connection = try await client.openArtifactLane(
                    resourceID: descriptor.resourceID,
                    offset: 0
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Descriptor mint/open failed before any lane byte was exposed.
                // Preserve compatibility by using the existing RPC path.
                return try await fetchArtifactChunksOverRPC(
                    method: method,
                    stringParams: stringParams,
                    collectsData: collectsData,
                    progress: progress,
                    onChunk: onChunk
                )
            }
            do {
                return try await MobileArtifactLaneFetchLoop().run(
                    descriptor: descriptor,
                    connection: connection,
                    collectsData: collectsData,
                    progress: progress,
                    onChunk: onChunk
                )
            } catch MobileArtifactLaneFetchError.failedBeforeFirstByte {
                // No consumer-visible bytes were delivered, so the legacy
                // authorized RPC can safely restart from offset zero.
            } catch is CancellationError {
                throw CancellationError()
            } catch MobileArtifactLaneFetchError.failedAfterFirstByte {
                // Once the lane exposed bytes, mixing in an RPC restart could
                // splice two file versions into one preview.
                throw ChatArtifactError.transferInterrupted
            } catch MobileArtifactLaneFetchError.invalidDescriptor {
                throw ChatArtifactError.invalidResponse
            }
        }
        return try await fetchArtifactChunksOverRPC(
            method: method,
            stringParams: stringParams,
            collectsData: collectsData,
            progress: progress,
            onChunk: onChunk
        )
    }

    private func fetchArtifactChunksOverRPC(
        method: String,
        stringParams: [String: String],
        collectsData: Bool,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?,
        onChunk: @Sendable (ChatArtifactChunk) async throws -> Void
    ) async throws -> Data {
        let loop = MobileArtifactChunkFetchLoop()
        return try await loop.run(
            collectsData: collectsData,
            progress: progress
        ) { offset in
            var params: [String: Any] = stringParams
            params["offset"] = offset
            params["length"] = ChatArtifactTransferPolicy.defaultPolicy.maxRawChunkBytes
            return try await self.artifactCall(method: method, params: params)
        } onChunk: { chunk in
            try await onChunk(chunk)
        }
    }

}
