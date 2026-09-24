import Foundation

/// One cmux-tui control connection carried over an SSH exec channel running
/// `cmux-tui relay`. Speaks the JSON-lines raw protocol (v11+): requests are
/// correlated by string id, and `attach-surface`/`subscribe` event lines are
/// routed by `event` and `surface`.
///
/// Requests are written in call order through one serial writer, so input
/// sent to a surface stays ordered. The server answers terminal queries
/// (DA, DSR, OSC color, Kitty graphics) itself: a phone mirror must discard
/// every reply its local terminal would write back to the PTY.
public actor CmuxTUIControl {
    /// Oldest raw protocol this client decodes (terminal lifecycle results
    /// and per-surface sizing).
    public static let minimumProtocol = 11
    /// Capabilities the client requires from the server.
    public static let requiredCapabilities: Set<String> = ["workspace-registry-v1", "attach-initial-size"]
    /// Client capabilities echoed through `set-client-info` when offered.
    static let clientCapabilities = ["view-attachment-lease-v1", "view-attachment-detach-v1", browserPointerGuardCapability]
    /// Required on both peers before a browser surface can be attached.
    public static let browserPointerGuardCapability = "browser-pointer-frame-guard-v1"

    public nonisolated let session: String
    private let channel: SSHSessionChannel
    private let outbound: AsyncStream<Data>.Continuation
    private var serverInfo: CmuxTUIServerInfo?
    private var nextRequest = 0
    private var pending: [String: CheckedContinuation<Data, any Error>] = [:]
    private var attachments: [Int: AsyncStream<CmuxTUIAttachEvent>.Continuation] = [:]
    private var browserAttachments: [Int: AsyncStream<CmuxTUIBrowserEvent>.Continuation] = [:]
    private var subscription: AsyncStream<CmuxTUIControlEvent>.Continuation?
    private var lines = CmuxTUILineBuffer()
    private var stderrTail = Data()
    private var exitStatus: Int?
    private var closed = false
    private var resourceScope: (machine: String, session: String)?

    private init(channel: SSHSessionChannel, session: String) {
        self.channel = channel
        self.session = session
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.outbound = continuation
        Task {
            for await line in stream {
                do { try await channel.write(line) } catch {
                    await channel.close()
                    return
                }
            }
        }
    }

    static func open(
        channel: SSHSessionChannel,
        session: String,
        clientName: String,
        handshakeTimeout: Duration
    ) async throws -> CmuxTUIControl {
        let control = CmuxTUIControl(channel: channel, session: session)
        Task { [weak control] in
            for await event in channel.events {
                guard let control else { break }
                await control.ingest(event)
            }
            await control?.transportClosed()
        }
        let watchdog = Task {
            try await Task.sleep(for: handshakeTimeout)
            await channel.close()
        }
        defer { watchdog.cancel() }
        do {
            try await control.handshake(clientName: clientName)
        } catch {
            await channel.close()
            throw await control.startupError(for: error)
        }
        return control
    }

    /// The server's `identify` result.
    public var server: CmuxTUIServerInfo {
        // Set by `open` before the control is returned.
        serverInfo!
    }

    /// Closes the relay channel. Terminals keep running on the host.
    public func close() async {
        await channel.close()
    }

    // MARK: - Workspaces

    /// Every workspace with its PTY terminals.
    public func listWorkspaces() async throws -> [CmuxTUIWorkspace] {
        try await request("list-workspaces", as: CmuxTUITreeWire.self).model
    }

    /// Creates a workspace, optionally with one terminal sized to the phone.
    public func createWorkspace(
        name: String? = nil,
        withTerminal: Bool = true,
        cols: Int? = nil,
        rows: Int? = nil,
        cwd: String? = nil,
        command: String? = nil
    ) async throws -> CmuxTUICreatedWorkspace {
        var params: [String: CmuxTUIWireValue] = [:]
        if let name { params["name"] = .string(name) }
        let created = try await request("create-workspace", params, as: CmuxTUIWorkspaceMutationWire.self)
        var result = CmuxTUICreatedWorkspace(workspace: created.workspace, key: created.key, terminal: nil)
        if withTerminal {
            result.terminal = try await createTerminal(inWorkspace: created.key, cols: cols, rows: rows, cwd: cwd, command: command)
        }
        return result
    }

    /// Creates a PTY terminal in the workspace with stable `key`. `command`
    /// runs through the default shell; `nil` starts the login shell.
    public func createTerminal(
        inWorkspace key: String,
        cols: Int? = nil,
        rows: Int? = nil,
        cwd: String? = nil,
        command: String? = nil,
        name: String? = nil
    ) async throws -> CmuxTUICreatedTerminal {
        var params: [String: CmuxTUIWireValue] = ["key": .string(key)]
        if let cols, let rows {
            params["cols"] = .int(cols)
            params["rows"] = .int(rows)
        }
        if let cwd { params["cwd"] = .string(cwd) }
        if let command { params["command"] = .string(command) }
        if let name { params["name"] = .string(name) }
        return try await request("create-terminal", params, as: CmuxTUICreateTerminalWire.self).model
    }

    /// Renames the workspace with stable `key`.
    public func renameWorkspace(key: String, name: String) async throws {
        _ = try await request("rename-workspace", ["key": .string(key), "name": .string(name)], as: CmuxTUIWorkspaceMutationWire.self)
    }

    /// Closes a workspace. `close-workspace` only removes views, leaving the
    /// terminal processes running unplaced, so by default this first
    /// terminates every terminal placed in the workspace.
    public func closeWorkspace(key: String, closeTerminals: Bool = true) async throws {
        if closeTerminals {
            let workspace = try await listWorkspaces().first { $0.key == key }
            for resourceID in Set(workspace?.terminals.compactMap(\.resourceID) ?? []) {
                try await closeTerminal(resourceID: resourceID)
            }
        }
        _ = try await request("close-workspace", ["key": .string(key)], as: CmuxTUIWorkspaceMutationWire.self)
    }

    /// Terminates and tombstones a terminal (resource API `terminal.close`).
    public func closeTerminal(resourceID: String) async throws {
        let scope = try await resolveResourceScope()
        _ = try await requestV2(
            "terminal.close",
            ["machine": .string(scope.machine), "session": .string(scope.session), "terminal": .string(resourceID)],
            idempotencyKey: UUID().uuidString,
            as: CmuxTUIEmptyMutationWire.self
        )
    }

    // MARK: - Terminals

    /// Attaches to a PTY surface in byte mode and, by default, claims
    /// exclusive geometry authority at `cols` x `rows` so the canonical grid
    /// follows the phone. The stream starts with `.vtState`; a claim that
    /// changes the grid is followed by `.resized`. One attachment per surface
    /// per connection.
    public func attach(surface: Int, cols: Int, rows: Int, claimGeometry: Bool = true) async throws -> CmuxTUIAttachment {
        guard attachments[surface] == nil else { throw CmuxTUIError.alreadyAttached(surface) }
        let (stream, continuation) = AsyncStream<CmuxTUIAttachEvent>.makeStream(bufferingPolicy: .unbounded)
        // vt-state arrives before the response, so route before sending.
        attachments[surface] = continuation
        do {
            let result = try await request(
                "attach-surface",
                ["surface": .int(surface), "mode": .string("bytes"), "cols": .int(cols), "rows": .int(rows)],
                as: CmuxTUIAttachResultWire.self
            )
            if claimGeometry {
                try await request(
                    "set-client-sizing",
                    ["surface": .int(surface), "enabled": .bool(true), "exclusive": .bool(true)],
                    as: CmuxTUIEmpty.self
                )
            }
            return CmuxTUIAttachment(control: self, surface: surface, lease: result.lease, events: stream)
        } catch {
            finishAttachment(surface, with: nil)
            throw error
        }
    }

    /// Writes raw bytes to a surface's PTY input.
    public func send(_ bytes: Data, to surface: Int) async throws {
        try await request("send", ["surface": .int(surface), "bytes": .string(bytes.base64EncodedString())], as: CmuxTUIEmpty.self)
    }

    /// Reports the phone's grid for an attachment. With geometry authority
    /// this resizes the PTY and a `.resized` frame follows.
    public func resize(_ attachment: CmuxTUIAttachment, cols: Int, rows: Int) async throws -> CmuxTUIResizeOutcome {
        let size: [String: CmuxTUIWireValue] = ["surface": .int(attachment.surface), "cols": .int(cols), "rows": .int(rows)]
        if let lease = attachment.lease {
            var params = size
            params["lease"] = .string(lease)
            let result = try await request("resize-attached-view", params, as: CmuxTUIOutcomeWire.self)
            return result.outcome.flatMap(CmuxTUIResizeOutcome.init(rawValue:)) ?? .passive
        }
        let result = try await request("resize-surface", size, as: CmuxTUIOutcomeWire.self)
        return result.accepted == true ? .applied : .passive
    }

    /// Ends one attach stream. The terminal keeps running. Geometry stays
    /// frozen at its current size until a new attachment claims it.
    public func detach(_ attachment: CmuxTUIAttachment) async throws {
        guard attachments[attachment.surface] != nil else { return }
        try await detachView(surface: attachment.surface, lease: attachment.lease)
    }

    private func detachView(surface: Int, lease: String?) async throws {
        if let lease, server.capabilities.contains("view-attachment-detach-v1") {
            // The response is a cleanup fence: no frames for this stream follow it.
            _ = try await request(
                "detach-attached-view",
                ["surface": .int(surface), "lease": .string(lease)],
                as: CmuxTUIOutcomeWire.self
            )
            finishAttachment(surface, with: nil)
            finishBrowserAttachment(surface, with: nil)
        } else {
            // Without targeted detach the transport is the only cleanup fence.
            await close()
        }
    }

    // MARK: - Browsers

    /// Whether the server can stream browser surfaces to this client.
    public var supportsBrowserAttach: Bool {
        server.capabilities.contains(Self.browserPointerGuardCapability)
    }

    /// Attaches to a browser surface. The stream starts with `.state`
    /// carrying the latest frame (if any), then `.state`/`.frame` updates.
    /// `cols`/`rows` report this view's size (browsers use the smallest
    /// reported grid); pass `nil` to leave the size alone.
    public func attachBrowser(surface: Int, cols: Int? = nil, rows: Int? = nil) async throws -> CmuxTUIBrowserAttachment {
        guard supportsBrowserAttach else { throw CmuxTUIError.missingCapability(Self.browserPointerGuardCapability) }
        guard browserAttachments[surface] == nil else { throw CmuxTUIError.alreadyAttached(surface) }
        // Frames are superseding pixels; a bounded buffer drops the oldest.
        let (stream, continuation) = AsyncStream<CmuxTUIBrowserEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        browserAttachments[surface] = continuation
        var params: [String: CmuxTUIWireValue] = ["surface": .int(surface), "mode": .string("bytes")]
        if let cols, let rows {
            params["cols"] = .int(max(1, cols))
            params["rows"] = .int(max(1, rows))
        }
        do {
            let result = try await request("attach-surface", params, as: CmuxTUIAttachResultWire.self)
            return CmuxTUIBrowserAttachment(control: self, surface: surface, lease: result.lease, events: stream)
        } catch {
            finishBrowserAttachment(surface, with: nil)
            throw error
        }
    }

    /// Ends one browser attach stream and releases its size report.
    public func detach(_ attachment: CmuxTUIBrowserAttachment) async throws {
        guard browserAttachments[attachment.surface] != nil else { return }
        try await detachView(surface: attachment.surface, lease: attachment.lease)
    }

    /// Tells the server the bitmap carrying pointer `token` is on screen,
    /// which authorizes guarded pointer input against it.
    public func presentBrowserFrame(surface: Int, token: UInt64) async throws {
        try await request("browser-frame-presented", ["surface": .int(surface), "frame_seq": .uint(token)], as: CmuxTUIEmpty.self)
    }

    /// Sends a guarded mouse event at page CSS-pixel coordinates.
    public func browserMouse(
        surface: Int,
        kind: CmuxTUIBrowserMouseKind,
        x: Double,
        y: Double,
        button: String? = "left",
        clickCount: Int? = 1,
        token: UInt64
    ) async throws {
        var params: [String: CmuxTUIWireValue] = [
            "surface": .int(surface),
            "kind": .string(kind.rawValue),
            "x_px": .double(x),
            "y_px": .double(y),
            "frame_seq": .uint(token),
        ]
        if let button { params["button"] = .string(button) }
        if let clickCount { params["click_count"] = .int(clickCount) }
        try await request("browser-mouse-guarded", params, as: CmuxTUIEmpty.self)
    }

    /// Sends a guarded vertical wheel event (positive `deltaY` scrolls down).
    public func browserWheel(surface: Int, x: Double, y: Double, deltaY: Double, token: UInt64) async throws {
        try await request(
            "browser-wheel-guarded",
            ["surface": .int(surface), "x_px": .double(x), "y_px": .double(y), "delta_y_px": .double(deltaY), "frame_seq": .uint(token)],
            as: CmuxTUIEmpty.self
        )
    }

    /// Inserts committed text at the page's focused element.
    public func browserInsertText(surface: Int, text: String) async throws {
        try await request("browser-insert-text", ["surface": .int(surface), "text": .string(text)], as: CmuxTUIEmpty.self)
    }

    /// Presses and releases one key.
    public func browserKeyPress(surface: Int, key: CmuxTUIBrowserKey) async throws {
        var params: [String: CmuxTUIWireValue] = [
            "surface": .int(surface),
            "key": .string(key.key),
            "code": .string(key.code),
            "windows_virtual_key_code": .int(key.windowsVirtualKeyCode),
            "modifiers": .int(key.modifiers),
        ]
        if let text = key.text { params["text"] = .string(text) }
        try await request("browser-key-press", params, as: CmuxTUIEmpty.self)
    }

    /// Navigates to a URL (normalized by the browser runtime).
    public func browserNavigate(surface: Int, url: String) async throws {
        try await request("browser-navigate", ["surface": .int(surface), "url": .string(url)], as: CmuxTUIEmpty.self)
    }

    public func browser(_ navigation: CmuxTUIBrowserNavigation, surface: Int) async throws {
        try await request(navigation.rawValue, ["surface": .int(surface)], as: CmuxTUIEmpty.self)
    }

    /// Reports this view's cell grid for a browser. Returns whether the
    /// server applied or queued a resize (completion arrives as state).
    @discardableResult
    public func resizeBrowser(surface: Int, cols: Int, rows: Int) async throws -> Bool {
        let result = try await request(
            "resize-surface",
            ["surface": .int(surface), "cols": .int(max(1, cols)), "rows": .int(max(1, rows))],
            as: CmuxTUIOutcomeWire.self
        )
        return result.accepted == true
    }

    /// The session's cell size in pixels. A browser's CSS viewport is its
    /// cell grid times this size; use it to turn a pixel viewport into cells.
    public func cellPixels() async throws -> (width: Int, height: Int) {
        let result = try await request("get-cell-pixels", as: CmuxTUICellPixelsWire.self)
        return (max(1, result.width_px), max(1, result.height_px))
    }

    /// Starts session-wide notifications (tree, titles, exits). Call once per
    /// connection; a second call replaces the previous stream.
    public func subscribe() async throws -> AsyncStream<CmuxTUIControlEvent> {
        let (stream, continuation) = AsyncStream<CmuxTUIControlEvent>.makeStream(bufferingPolicy: .bufferingNewest(1024))
        subscription?.finish()
        subscription = continuation
        do {
            try await request("subscribe", as: CmuxTUIEmpty.self)
        } catch {
            continuation.finish()
            subscription = nil
            throw error
        }
        return stream
    }

    // MARK: - Requests

    @discardableResult
    func request<T: Decodable>(_ command: String, _ params: [String: CmuxTUIWireValue] = [:], as type: T.Type) async throws -> T {
        var object = params
        object["cmd"] = .string(command)
        let line = try await roundTrip(object)
        let response = try CmuxTUIWire.decode(CmuxTUIRawResponse<T>.self, from: line)
        guard response.ok else {
            throw CmuxTUIError.commandFailed(command: command, message: response.error ?? "unknown error", code: response.error_code)
        }
        if let data = response.data { return data }
        if let empty = CmuxTUIEmpty() as? T { return empty }
        throw CmuxTUIError.malformedResponse("\(command): missing data")
    }

    func requestV2<T: Decodable>(
        _ operation: String,
        _ params: [String: CmuxTUIWireValue],
        idempotencyKey: String? = nil,
        as type: T.Type
    ) async throws -> T {
        var object: [String: CmuxTUIWireValue] = [
            "protocol": .string("cmux.protocol/2"),
            "type": .string("request"),
            "operation": .string(operation),
            "params": .object(params),
        ]
        if let idempotencyKey { object["idempotency_key"] = .string(idempotencyKey) }
        let line = try await roundTrip(object)
        let response = try CmuxTUIWire.decode(CmuxTUIV2Response<T>.self, from: line)
        guard response.ok, let result = response.result else {
            throw CmuxTUIError.commandFailed(
                command: operation,
                message: response.error?.message ?? "unknown error",
                code: response.error?.code
            )
        }
        return result
    }

    /// Sends one request line and waits for the line carrying its id.
    private func roundTrip(_ object: [String: CmuxTUIWireValue]) async throws -> Data {
        guard !closed else { throw CmuxTUIError.closed }
        nextRequest += 1
        let id = "r\(nextRequest)"
        var object = object
        object["id"] = .string(id)
        let line = try CmuxTUIWire.line(object)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Registered and enqueued synchronously, so writes keep call order.
                pending[id] = continuation
                outbound.yield(line)
            }
        } onCancel: {
            Task { await self.fail(id, with: CancellationError()) }
        }
    }

    private func fail(_ id: String, with error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func resolveResourceScope() async throws -> (machine: String, session: String) {
        if let resourceScope { return resourceScope }
        let machines = try await requestV2("machine.list", [:], as: [CmuxTUIResourceIDWire].self)
        guard let machine = machines.first?.id else { throw CmuxTUIError.malformedResponse("machine.list: empty") }
        let sessions = try await requestV2("session.list", ["machine": .string(machine)], as: [CmuxTUIResourceIDWire].self)
        guard let session = (sessions.first { $0.name == self.session } ?? sessions.first)?.id else {
            throw CmuxTUIError.malformedResponse("session.list: empty")
        }
        resourceScope = (machine, session)
        return (machine, session)
    }

    // MARK: - Handshake

    private func handshake(clientName: String) async throws {
        let identify = try await request("identify", as: CmuxTUIIdentifyWire.self)
        let info = CmuxTUIServerInfo(
            app: identify.app,
            version: identify.version,
            protocolVersion: identify.protocol_,
            capabilities: Set(identify.capabilities ?? []),
            session: identify.session,
            pid: identify.pid,
            generation: identify.generation,
            buildCommit: identify.build_commit
        )
        guard info.protocolVersion >= Self.minimumProtocol else {
            throw CmuxTUIError.unsupportedProtocol(info.protocolVersion)
        }
        for capability in Self.requiredCapabilities.sorted() where !info.capabilities.contains(capability) {
            throw CmuxTUIError.missingCapability(capability)
        }
        serverInfo = info
        let offered = Self.clientCapabilities.filter(info.capabilities.contains)
        try await request(
            "set-client-info",
            ["name": .string(clientName), "kind": .string("ios"), "capabilities": .strings(offered)],
            as: CmuxTUIEmpty.self
        )
    }

    private func startupError(for error: any Error) -> any Error {
        guard let error = error as? CmuxTUIError, error == .closed else { return error }
        let message = String(decoding: stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return CmuxTUIError.serverStartFailed(exitStatus: exitStatus, message: message)
    }

    // MARK: - Inbound

    private func ingest(_ event: SSHSessionEvent) {
        switch event {
        case .stdout(let data):
            for line in lines.append(data) { route(line) }
        case .stderr(let data):
            stderrTail.append(data)
            if stderrTail.count > 8192 { stderrTail.removeFirst(stderrTail.count - 8192) }
        case .exitStatus(let status):
            exitStatus = status
        case .exitSignal:
            exitStatus = exitStatus ?? -1
        case .closed:
            transportClosed()
        }
    }

    private func route(_ line: Data) {
        guard let envelope = try? JSONDecoder().decode(CmuxTUIRoutingEnvelope.self, from: line) else { return }
        if let id = envelope.id {
            pending.removeValue(forKey: id)?.resume(returning: line)
        } else if envelope.event == "browser-state" || envelope.event == "frame" {
            // Browser lines carry large base64 PNGs; decode them once.
            guard let decoded = CmuxTUIBrowserWire.event(from: line) else { return }
            browserAttachments[decoded.surface]?.yield(decoded.event)
        } else if envelope.event != nil, let event = try? JSONDecoder().decode(CmuxTUIEventWire.self, from: line) {
            dispatch(event, line: line)
        }
        // A bad-JSON reply has no id and cannot be correlated; drop it.
    }

    private func dispatch(_ event: CmuxTUIEventWire, line: Data) {
        switch event.event {
        case "vt-state":
            guard let surface = event.surface, let attachment = attachments[surface] else { return }
            attachment.yield(.vtState(CmuxTUIWire.base64(event.data), cols: event.cols ?? 0, rows: event.rows ?? 0))
            if let colors = event.colors { attachment.yield(.colors(colors.model)) }
        case "output":
            guard let surface = event.surface, let attachment = attachments[surface] else { return }
            attachment.yield(.output(CmuxTUIWire.base64(event.data)))
            if let colors = event.colors { attachment.yield(.colors(colors.model)) }
        case "resized":
            guard let surface = event.surface, let attachment = attachments[surface] else { return }
            // Protocol 7+ uses `replay`; v6 used `data`.
            let replay = CmuxTUIWire.base64(event.replay ?? event.data)
            attachment.yield(.resized(cols: event.cols ?? 0, rows: event.rows ?? 0, replay: replay))
            if let colors = event.colors { attachment.yield(.colors(colors.model)) }
        case "colors-changed":
            guard let surface = event.surface, let attachment = attachments[surface],
                  let colors = try? JSONDecoder().decode(CmuxTUIColorsWire.self, from: line) else { return }
            attachment.yield(.colors(colors.model))
        case "detached":
            guard let surface = event.surface else { return }
            finishAttachment(surface, with: .exited)
            finishBrowserAttachment(surface, with: .ended)
        case "tree-changed":
            subscription?.yield(.treeChanged)
        case "title-changed":
            if let surface = event.surface { subscription?.yield(.titleChanged(surface: surface, title: event.title ?? "")) }
        case "surface-exited":
            if let surface = event.surface { subscription?.yield(.surfaceExited(surface: surface)) }
        case "surface-resized":
            if let surface = event.surface, let cols = event.cols, let rows = event.rows {
                subscription?.yield(.surfaceResized(surface: surface, cols: cols, rows: rows))
            }
        case "bell":
            if let surface = event.surface { subscription?.yield(.bell(surface: surface)) }
        case "empty":
            subscription?.yield(.empty)
        case "overflow":
            subscription?.yield(.overflow)
            subscription?.finish()
            subscription = nil
        case "daemon-shutdown":
            subscription?.yield(.daemonShutdown)
        default:
            break
        }
    }

    fileprivate func finishAttachment(_ surface: Int, with last: CmuxTUIAttachEvent?) {
        guard let attachment = attachments.removeValue(forKey: surface) else { return }
        if let last { attachment.yield(last) }
        attachment.finish()
    }

    fileprivate func finishBrowserAttachment(_ surface: Int, with last: CmuxTUIBrowserEvent?) {
        guard let attachment = browserAttachments.removeValue(forKey: surface) else { return }
        if let last { attachment.yield(last) }
        attachment.finish()
    }

    private func transportClosed() {
        guard !closed else { return }
        closed = true
        outbound.finish()
        for continuation in pending.values { continuation.resume(throwing: CmuxTUIError.closed) }
        pending.removeAll()
        for surface in Array(attachments.keys) { finishAttachment(surface, with: .disconnected) }
        for surface in Array(browserAttachments.keys) { finishBrowserAttachment(surface, with: .disconnected) }
        subscription?.yield(.disconnected)
        subscription?.finish()
        subscription = nil
    }
}

/// A byte-mode attach stream for one surface on one control connection.
public struct CmuxTUIAttachment: Sendable {
    public let control: CmuxTUIControl
    public let surface: Int
    /// View lease (`view-attachment-lease-v1`) fencing resize and detach to
    /// this exact stream.
    public let lease: String?
    /// Ordered frames; finishes after `.exited`, `.disconnected`, or `detach()`.
    public let events: AsyncStream<CmuxTUIAttachEvent>

    /// Sends keyboard or paste bytes to the terminal.
    public func write(_ bytes: Data) async throws {
        try await control.send(bytes, to: surface)
    }

    public func resize(cols: Int, rows: Int) async throws -> CmuxTUIResizeOutcome {
        try await control.resize(self, cols: cols, rows: rows)
    }

    public func detach() async throws {
        try await control.detach(self)
    }
}

struct CmuxTUIEmptyMutationWire: Decodable {
    var replayed: Bool?
}

/// A browser attach stream for one surface on one control connection.
public struct CmuxTUIBrowserAttachment: Sendable {
    public let control: CmuxTUIControl
    public let surface: Int
    public let lease: String?
    /// Ordered events; finishes after `.ended`, `.disconnected`, or `detach()`.
    public let events: AsyncStream<CmuxTUIBrowserEvent>

    public func detach() async throws {
        try await control.detach(self)
    }
}

// MARK: - Idle close (PRD D13)

extension CmuxTUIControl {
    /// Server capability for `set-terminal-idle-policy`.
    public static let idleCloseCapability = "terminal-idle-close-v1"

    /// Stores the idle-close policy of the terminal behind `surface`: the
    /// server closes it once it has had no attached view for `seconds`;
    /// `nil` clears the policy so it is never closed for idleness. The policy
    /// is durable on the server. Returns `false` without sending anything
    /// when the server predates `terminal-idle-close-v1`.
    @discardableResult
    public func setIdlePolicy(surface: Int, seconds: Int?) async throws -> Bool {
        guard server.capabilities.contains(Self.idleCloseCapability) else { return false }
        var params: [String: CmuxTUIWireValue] = ["surface": .int(surface)]
        // An omitted `idle_close_seconds` clears the policy.
        if let seconds { params["idle_close_seconds"] = .int(seconds) }
        try await request("set-terminal-idle-policy", params, as: CmuxTUIEmpty.self)
        return true
    }
}

// MARK: - Resync

extension CmuxTUIControl {
    /// Server capability for targeted `detach-attached-view`.
    public static let viewDetachCapability = "view-attachment-detach-v1"

    /// Whether this connection has a live byte-mode stream for `surface`.
    public func isAttached(surface: Int) -> Bool {
        attachments[surface] != nil
    }

    /// Whether `attachment` can be replaced in place by `reattach`.
    public func canReattach(_ attachment: CmuxTUIAttachment) -> Bool {
        attachment.lease != nil && server.capabilities.contains(Self.viewDetachCapability)
    }

    /// Replaces `attachment` with a fresh stream on this same connection. The
    /// detach response fences the old stream, and the new stream starts with
    /// a `vt-state` captured after it, so no output is lost between them.
    /// The new attachment claims geometry at `cols` x `rows` like `attach`.
    ///
    /// Returns `nil` without detaching when the server lacks targeted detach
    /// (`view-attachment-detach-v1`), because the only other cleanup fence
    /// closes the whole connection.
    public func reattach(_ attachment: CmuxTUIAttachment, cols: Int, rows: Int) async throws -> CmuxTUIAttachment? {
        guard canReattach(attachment) else { return nil }
        try await detach(attachment)
        return try await attach(surface: attachment.surface, cols: cols, rows: rows)
    }
}
