import CmuxNextDaemon
import Foundation
@testable import CmuxNextMobile

/// In-memory daemon for compat tests: a fixed tree plus scripted attach events.
final class FakeCompatBackend: MobileCompatBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _tree: DaemonTree
    private var _sent: [(SurfaceID, Data, Bool)] = []
    private var _attachSizes: [CellSize] = []
    private var channels: [FakeTerminalChannel] = []
    let changes = TreeChangeBroadcaster()

    init(tree: DaemonTree) { _tree = tree }

    var sent: [(SurfaceID, Data, Bool)] { lock.withLock { _sent } }
    var attachSizes: [CellSize] { lock.withLock { _attachSizes } }
    var lastChannel: FakeTerminalChannel? { lock.withLock { channels.last } }

    func tree() async throws -> DaemonTree { lock.withLock { _tree } }
    func treeChanges() -> AsyncStream<Void> { changes.subscribe() }
    func createWorkspace(name: String?) async throws -> WorkspaceKey { "11111111-2222-3333-4444-555555555555" }
    func renameWorkspace(_ key: WorkspaceKey, to name: String) async throws {}
    func closeWorkspace(_ key: WorkspaceKey) async throws {}
    func createTerminal(in key: WorkspaceKey, cwd: String?) async throws -> TerminalID? {
        "0123456789abcdef0123456789abcdef"
    }
    func send(_ surface: SurfaceID, bytes: Data, paste: Bool) async throws {
        lock.withLock { _sent.append((surface, bytes, paste)) }
    }
    func renameTab(_ surface: SurfaceID, to name: String) async throws {}
    func closeTerminal(_ terminal: TerminalID) async throws {}

    func attach(_ tab: TabSnapshot, generation: DaemonGeneration?, size: CellSize) async throws
        -> any MobileCompatTerminalChannel {
        let channel = FakeTerminalChannel()
        lock.withLock {
            _attachSizes.append(size)
            channels.append(channel)
        }
        channel.push(.replay(TerminalReplay(cols: size.cols, rows: size.rows, data: Data("\u{1B}[1mhello\u{1B}[0m\r\n$ ".utf8),
                                             colors: nil)))
        return channel
    }
}

final class FakeTerminalChannel: MobileCompatTerminalChannel, @unchecked Sendable {
    let events: AsyncStream<TerminalChannelEvent>
    private let continuation: AsyncStream<TerminalChannelEvent>.Continuation
    private let lock = NSLock()
    private var _resizes: [CellSize] = []
    private var _claims = 0

    init() { (events, continuation) = AsyncStream.makeStream() }

    var resizes: [CellSize] { lock.withLock { _resizes } }
    var claims: Int { lock.withLock { _claims } }

    func push(_ event: TerminalChannelEvent) { continuation.yield(event) }
    func resize(cols: Int, rows: Int) async { lock.withLock { _resizes.append(CellSize(cols: cols, rows: rows)) } }
    func claimGeometry() async { lock.withLock { _claims += 1 } }
    func releaseGeometry() async {}
    func detach() async { continuation.finish() }
}

/// Collects emitted event frames.
actor EventRecorder {
    private(set) var frames: [Data] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    nonisolated func emit() -> MobileCompatSession.Emit {
        { data in await self.record(data) }
    }

    private func record(_ data: Data) {
        frames.append(data)
        let ready = waiters.filter { $0.0 <= frames.count }
        waiters.removeAll { $0.0 <= frames.count }
        for waiter in ready { waiter.1.resume() }
    }

    func wait(for count: Int) async {
        if frames.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

extension Array where Element == Data {
    /// Decoded event objects (tests only).
    var eventObjects: [[String: Any]] {
        compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
