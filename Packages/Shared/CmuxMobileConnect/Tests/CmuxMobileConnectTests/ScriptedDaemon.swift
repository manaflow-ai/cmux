import CmuxLinkTesting
import CmuxMobileHost
import CmuxMobileWire
import CmuxTerminalStream
import Foundation

/// A session host with one terminal (`term_x1`): every attach is handed to
/// the test, which scripts its output; a viewport report changes the grid
/// (a new generation with its READY), like the smallest-viewer reducer.
actor ScriptedDaemon: MobileDaemon {
    static let state = MobileWorkspaceState(host: ConnectFixture.hostID, workspaces: [
        MobileWorkspace(id: "ws_a1", name: "main", order: 0, panes: [
            MobilePane(id: "pane_p1", tabs: [
                MobileTab(id: "tab_t1", kind: .terminal, title: "zsh", terminal: "term_x1", status: .idle, unread: 0),
            ]),
        ]),
    ])

    let attachments = AsyncQueue<ScriptedAttachment>()

    func workspaceState() async throws -> MobileWorkspaceState { Self.state }
    func workspaceChanges() async -> AsyncStream<Void> { AsyncStream { _ in } }
    func perform(_ op: MobileDaemonOp, context: MobileOpContext) async throws -> MobileDaemonOpResult { MobileDaemonOpResult() }

    func attachTerminal(_ request: MobileTerminalAttachRequest) async throws -> any MobileTerminalAttachment {
        guard request.terminal == "term_x1" else { throw MobileDaemonError(code: "terminal.not_found", message: "no such terminal") }
        let attachment = ScriptedAttachment(request: request)
        await attachments.push(attachment)
        return attachment
    }
}

actor ScriptedAttachment: MobileTerminalAttachment {
    nonisolated let request: MobileTerminalAttachRequest
    nonisolated let opened: TerminalOpenedParams
    nonisolated let events: AsyncStream<MobileTerminalEvent>
    private nonisolated let continuation: AsyncStream<MobileTerminalEvent>.Continuation
    private var generation: UInt32 = 7
    private(set) var typed = ""
    let recorded = AsyncQueue<String>()

    init(request: MobileTerminalAttachRequest) {
        self.request = request
        opened = TerminalOpenedParams(generation: 7, cols: request.viewport.cols, rows: request.viewport.rows,
                                      snapshotVersion: 1, title: "zsh")
        (events, continuation) = AsyncStream<MobileTerminalEvent>.makeStream()
    }

    nonisolated func ready(offset: UInt64, generation: UInt32 = 7) {
        continuation.yield(.frame(TerminalFrame(kind: .snapshotReady, generation: generation, offset: offset,
                                                snapshotVersion: 1, payload: Data("READY".utf8))))
    }

    nonisolated func bytes(_ text: String, endingAt offset: UInt64, generation: UInt32 = 7) {
        continuation.yield(.frame(TerminalFrame(kind: .bytes, generation: generation, offset: offset, payload: Data(text.utf8))))
    }

    func write(_ input: TerminalInput) async {
        typed += String(decoding: input.data, as: UTF8.self)
        await recorded.push("input:\(String(decoding: input.data, as: UTF8.self))")
    }

    func setViewport(_ viewport: TerminalViewport) async {
        generation += 1
        continuation.yield(.size(generation: generation, cols: viewport.cols, rows: viewport.rows))
        ready(offset: 2000, generation: generation)
        await recorded.push("viewport:\(viewport.cols)x\(viewport.rows)")
    }

    func setPresence(visible: Bool, counts: Bool) async {
        await recorded.push("presence:\(visible)")
    }

    func requestSnapshot(_ request: MobileSnapshotRequest) async {
        await recorded.push("snapshot:\(request.reason)")
    }

    func detach() async {
        continuation.finish()
        await recorded.push("detach")
    }

    /// Waits until the bridge forwarded `entry`.
    func waitFor(_ entry: String) async throws {
        try await within {
            while let next = await self.recorded.next() {
                if next == entry { return }
            }
            throw TimeoutError()
        }
    }
}
