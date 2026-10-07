import CmuxLinkTesting
import CmuxMobileHost
import CmuxMobileWire
import CmuxTerminalSizing
import CmuxTerminalStream
import Foundation

/// A daemon with one terminal (`term_x1`) whose attaches are scripted by
/// the test, plus the Mac's own view in a shared sizing reducer so presence
/// and viewport reports change the grid like the session host does.
actor ScriptedDaemon: MobileDaemon {
    static let state = MobileWorkspaceState(host: "h_mac1", workspaces: [
        MobileWorkspace(id: "ws_a1", name: "main", order: 0, panes: [
            MobilePane(id: "pane_p1", tabs: [
                MobileTab(id: "tab_t1", kind: .terminal, title: "zsh", terminal: "term_x1", status: .idle, unread: 0),
            ]),
        ]),
    ])

    let attachments = AsyncQueue<ScriptedAttachment>()
    private var sizing: TerminalSizingEngine
    private var generation: UInt32 = 7
    private var live: [UUID: ScriptedAttachment] = [:]

    init(macViewport: TerminalGridSize? = TerminalGridSize(cols: 150, rows: 42)) {
        sizing = TerminalSizingEngine(initialSize: TerminalGridSize(cols: 80, rows: 24), policy: .fitEveryone)
        if let macViewport {
            _ = sizing.attach(TerminalSizingParticipant(id: "mac", userID: "u_bob", deviceKind: .mac, viewport: macViewport))
        }
    }

    func workspaceState() async throws -> MobileWorkspaceState { Self.state }
    func workspaceChanges() async -> AsyncStream<Void> { AsyncStream { _ in } }
    func perform(_ op: MobileDaemonOp, context: MobileOpContext) async throws -> MobileDaemonOpResult { MobileDaemonOpResult() }

    var grid: TerminalGridSize { sizing.state.size }

    func attachTerminal(_ request: MobileTerminalAttachRequest) async throws -> any MobileTerminalAttachment {
        let id = UUID()
        let viewport = TerminalGridSize(cols: request.viewport.cols, rows: request.viewport.rows)
        _ = sizing.attach(TerminalSizingParticipant(id: id.uuidString, userID: "u_alice", deviceKind: .iphone,
                                                    viewport: request.visible ? viewport : nil))
        if !request.visible { _ = sizing.clearViewport(id.uuidString) }
        let size = sizing.state.size
        let attachment = ScriptedAttachment(id: id, daemon: self, request: request,
                                            opened: TerminalOpenedParams(generation: generation, cols: size.cols, rows: size.rows,
                                                                         snapshotVersion: 1, title: "zsh"))
        live[id] = attachment
        await attachments.push(attachment)
        return attachment
    }

    /// Applies one viewer's report; on a published change, every attach
    /// gets the new size and a READY of the new generation.
    func sizingChanged(_ change: (inout TerminalSizingEngine) -> Bool) {
        guard change(&sizing) else { return }
        generation += 1
        let size = sizing.state.size
        for attachment in live.values {
            attachment.emit(.size(generation: generation, cols: size.cols, rows: size.rows))
            attachment.emit(.frame(TerminalFrame(kind: .snapshotReady, generation: generation, offset: attachment.readyOffset,
                                                 snapshotVersion: 1, payload: Data("READY".utf8))))
        }
    }

    func detached(_ id: UUID) {
        live[id] = nil
        _ = sizing.detach(id.uuidString)
    }
}

/// One scripted attach: records what the bridge forwards, emits what the test says.
actor ScriptedAttachment: MobileTerminalAttachment {
    nonisolated let id: UUID
    nonisolated let request: MobileTerminalAttachRequest
    nonisolated let opened: TerminalOpenedParams
    nonisolated let events: AsyncStream<MobileTerminalEvent>
    private nonisolated let continuation: AsyncStream<MobileTerminalEvent>.Continuation
    private let daemon: ScriptedDaemon
    private(set) var inputs: [TerminalInput] = []
    private(set) var snapshotRequests: [MobileSnapshotRequest] = []
    private(set) var detachedFlag = false
    let recorded = AsyncQueue<String>()
    /// Offset a READY made by the daemon reflects (the test moves it).
    nonisolated var readyOffset: UInt64 { 1000 }

    init(id: UUID, daemon: ScriptedDaemon, request: MobileTerminalAttachRequest, opened: TerminalOpenedParams) {
        self.id = id
        self.daemon = daemon
        self.request = request
        self.opened = opened
        (events, continuation) = AsyncStream<MobileTerminalEvent>.makeStream()
    }

    nonisolated func emit(_ event: MobileTerminalEvent) { continuation.yield(event) }

    nonisolated func ready(offset: UInt64, generation: UInt32 = 7) {
        emit(.frame(TerminalFrame(kind: .snapshotReady, generation: generation, offset: offset, snapshotVersion: 1,
                                  payload: Data("READY".utf8))))
    }

    nonisolated func bytes(_ text: String, endingAt offset: UInt64, generation: UInt32 = 7) {
        emit(.frame(TerminalFrame(kind: .bytes, generation: generation, offset: offset, payload: Data(text.utf8))))
    }

    func write(_ input: TerminalInput) async {
        inputs.append(input)
        await recorded.push("input")
    }

    func setViewport(_ viewport: CmuxMobileWire.TerminalViewport) async {
        let id = id.uuidString
        await daemon.sizingChanged { $0.report(id, viewport: TerminalGridSize(cols: viewport.cols, rows: viewport.rows)) }
        await recorded.push("viewport:\(viewport.cols)x\(viewport.rows)")
    }

    func setPresence(visible: Bool, counts: Bool) async {
        let id = id.uuidString
        if !visible { await daemon.sizingChanged { $0.clearViewport(id) } }
        await recorded.push("presence:\(visible)")
    }

    func requestSnapshot(_ request: MobileSnapshotRequest) async {
        snapshotRequests.append(request)
        await recorded.push("snapshot:\(request.reason)")
    }

    /// The app adapter's answer until cmux-tui pages history.
    private(set) var refusesHistory = false

    func setRefusesHistory(_ refuses: Bool) { refusesHistory = refuses }

    nonisolated func history(offset: UInt64, generation: UInt32 = 7) {
        emit(.frame(TerminalFrame(kind: .snapshotHistory, generation: generation, offset: offset, snapshotVersion: 1,
                                  payload: Data("OLDER".utf8))))
    }

    func handle(_ message: ChannelMessage) async throws -> [ChannelMessage] {
        await recorded.push(message.name)
        if refusesHistory, message.name == "terminal.history" {
            throw MobileDaemonError(code: "proto.unsupported", message: "terminal.history is not supported by this host")
        }
        return []
    }

    func detach() async {
        detachedFlag = true
        continuation.finish()
        await daemon.detached(id)
        await recorded.push("detach")
    }

    /// The input bytes in arrival order.
    var typed: String { String(decoding: inputs.flatMap(\.data), as: UTF8.self) }
}
