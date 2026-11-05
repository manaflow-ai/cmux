import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

@MainActor
@Suite struct WorkspaceSyncReplayTests {
    /// Test both the setup list and the follow-up refresh used to load sidebar
    /// arrangement. Each reply has older title/add events before it and a newer
    /// title immediately after it, in a single channel read.
    @Test(arguments: [1, 2])
    func replayedAddsAreIdempotentAndLatestTitleWins(_ snapshotRequest: Int) async throws {
        let channel = ReplayDaemonChannel(replayOnRequest: snapshotRequest)
        defer { channel.finish() }
        let sync = WorkspaceSync(deviceID: "test", deviceName: "iPhone")
        let (updates, continuation) = AsyncStream<DaemonTree>.makeStream()
        defer { continuation.finish() }
        var published: [DaemonTree] = []
        sync.onTree = { tree in published.append(tree); continuation.yield(tree) }
        sync.onRows = { tree, _, _ in published.append(tree); continuation.yield(tree) }

        await sync.bind(channel, macID: "mac")
        let result = try await replayTree(updates) { tree in
            tree.workspaces.first?.tabs.first?.title == "after-snapshot"
        }
        #expect(result.workspaces.first?.tabs.map(\.id) == ["s1", "s2"])
        #expect(result.workspaces.first?.tabs.last?.title == "snapshot-tab")
        // Reply receipt is not a server snapshot watermark. Replaying an
        // earlier title temporarily is allowed; a replayed add must never
        // duplicate a tab or overwrite the entity held by the snapshot.
        #expect(published.allSatisfy { $0.workspaces.first?.tabs.count == 2 })
        #expect(published.allSatisfy { $0.workspaces.first?.tabs.last?.title == "snapshot-tab" })
        #expect(channel.listWorkspaceRequests >= snapshotRequest)
        await sync.bind(nil, macID: "mac")
    }

    /// The daemon can capture a snapshot, then send a newer title event
    /// before the older reply reaches the wire. No later event repairs it.
    @Test(arguments: [1, 3])
    func titleReceivedBeforeOlderReplySurvivesSnapshotCaptureRace(_ request: Int) async throws {
        let channel = ReplayDaemonChannel(captureRaceOnRequest: request)
        defer { channel.finish() }
        let sync = WorkspaceSync(deviceID: "test", deviceName: "iPhone")
        let (ready, readyContinuation) = AsyncStream<DaemonTree>.makeStream()
        let (rows, rowsContinuation) = AsyncStream<DaemonTree>.makeStream()
        defer { readyContinuation.finish(); rowsContinuation.finish() }
        var fullPublications = 0
        var capturedSnapshotPublished = false
        sync.onTree = { tree in
            fullPublications += 1
            if fullPublications == 2 { readyContinuation.yield(tree) }
            if channel.listWorkspaceRequests >= request,
               tree.workspaces.first?.tabs.first?.title == "snapshot-title" {
                capturedSnapshotPublished = true
            }
            // Initial setup legitimately follows with an arrangement list
            // whose newer capture can already contain the title.
            if request == 1, tree.workspaces.first?.tabs.first?.title == "newer-than-capture" {
                rowsContinuation.yield(tree)
            }
        }
        sync.onRows = { tree, _, _ in
            if tree.workspaces.first?.tabs.first?.title == "newer-than-capture" {
                #expect(capturedSnapshotPublished)
                rowsContinuation.yield(tree)
            }
        }
        await sync.bind(channel, macID: "mac")
        if request == 3 {
            _ = try await replayTree(ready) { _ in true }
            await sync.refresh()
        }
        let restored = try await replayTree(rows) { _ in true }
        #expect(restored.workspaces.first?.tabs.first?.title == "newer-than-capture")
        #expect(restored.workspaces.first?.tabs.map(\.id) == ["s1", "s2"])
        // For the explicit refresh only onRows satisfies the barrier; no
        // follow-up list can conceal a dropped event.
        await sync.bind(nil, macID: "mac")
    }

    /// Both changes must go through the full consumer callback: it invalidates
    /// stale agent bindings and reconciles the Feed's retained unread markers.
    @Test(arguments: ["agent-binding", "notification-marker"])
    func tabChangedUsesFullTreeConsumer(_ change: String) async throws {
        let initial = #"{"ok":true,"data":{"workspace_revision":1,"registry_id":"r","workspaces":[{"id":1,"key":"one","name":"One","screens":[{"id":1,"panes":[{"id":1,"tabs":[{"surface":1,"kind":"conversation","title":"Chat","conversation":{"agent_session":{"session":"old-session","harness":"codex"}}},{"surface":2,"kind":"pty","title":"Shell","notification":{"notification":9,"unread":true}}]}]}]}]}}"#
        let channel = ReplayDaemonChannel(snapshotBody: initial)
        defer { channel.finish() }
        let sync = WorkspaceSync(deviceID: "test", deviceName: "iPhone")
        let (ready, readyContinuation) = AsyncStream<DaemonTree>.makeStream()
        let (updates, updateContinuation) = AsyncStream<DaemonTree>.makeStream()
        defer { readyContinuation.finish(); updateContinuation.finish() }
        var fullPublications = 0
        var rowPublications = 0
        sync.onTree = { tree in
            fullPublications += 1
            if fullPublications == 2 { readyContinuation.yield(tree) }
            if fullPublications > 2 { updateContinuation.yield(tree) }
        }
        sync.onRows = { tree, _, _ in rowPublications += 1; updateContinuation.yield(tree) }
        await sync.bind(channel, macID: "mac")
        _ = try await replayTree(ready) { _ in true }

        if change == "agent-binding" {
            channel.emit(#"{"event":"tab-changed","workspace":1,"screen":1,"pane":1,"surface":1,"entity":{"surface":1,"kind":"conversation","title":"Chat","conversation":{"agent_session":{"session":"new-session","harness":"codex"}}}}"#)
        } else {
            channel.emit(#"{"event":"tab-changed","workspace":1,"screen":1,"pane":1,"surface":2,"entity":{"surface":2,"kind":"pty","title":"Shell","notification":{"notification":9,"unread":false}}}"#)
        }
        let updated = try await replayTree(updates) { tree in
            change == "agent-binding" ? tree.agentTabs["s1"]?.session == "new-session"
                : tree.notificationMarkers[2]?.unread == false
        }
        #expect(fullPublications == 3)
        #expect(rowPublications == 0)
        #expect(channel.listWorkspaceRequests == 2)
        if change == "agent-binding" { #expect(updated.agentTabs["s1"]?.session == "new-session") }
        else { #expect(updated.notificationMarkers[2]?.unread == false) }
        await sync.bind(nil, macID: "mac")
    }

    @Test func coarseEventBurstsCoalesceWithoutStarvingAgentUpdates() async throws {
        let (held, heldContinuation) = AsyncStream<Bool>.makeStream()
        let channel = ReplayDaemonChannel(holdSnapshotRequest: 3, onSnapshotHeld: { heldContinuation.yield(true) })
        defer { heldContinuation.finish(); channel.finish() }
        let sync = WorkspaceSync(deviceID: "test", deviceName: "iPhone")
        let (ready, readyContinuation) = AsyncStream<DaemonTree>.makeStream()
        let (agents, agentsContinuation) = AsyncStream<DaemonTree>.makeStream()
        let (settled, settledContinuation) = AsyncStream<DaemonTree>.makeStream()
        defer { readyContinuation.finish(); agentsContinuation.finish(); settledContinuation.finish() }
        var fullPublications = 0
        var agentFirstSeenAtPublication: Int?
        sync.onTree = { tree in
            fullPublications += 1
            if fullPublications == 2 { readyContinuation.yield(tree) }
            if fullPublications == 4 {
                channel.emit(#"{"event":"title-changed","surface":1,"title":"bursts-settled"}"#)
            }
        }
        sync.onRows = { tree, _, agentChanged in
            if agentChanged, tree.workspaces.first?.tabs.first?.agentStatus == .working {
                if agentFirstSeenAtPublication == nil { agentFirstSeenAtPublication = fullPublications }
                agentsContinuation.yield(tree)
            }
            if tree.workspaces.first?.tabs.first?.title == "bursts-settled" { settledContinuation.yield(tree) }
        }
        await sync.bind(channel, macID: "mac")
        _ = try await replayTree(ready) { _ in true }
        let personalBefore = channel.listPersonalRequests
        let layoutBefore = channel.sidebarLayoutRequests
        let coarse = #"{"event":"tab-changed","workspace":1,"screen":1,"pane":1,"surface":1}"#
        let agent = #"{"event":"agent-changed","surface":1,"state":"working","agent":"codex"}"#
        channel.emitBatch(Array(repeating: coarse, count: 64) + [agent])
        _ = try await replayValue(held) { $0 }
        // A second burst lands after the first recovery request has begun;
        // its changes legitimately require one further recovery snapshot.
        channel.emitBatch(Array(repeating: coarse, count: 64))
        channel.releaseHeldSnapshot()
        _ = try await replayTree(agents) { _ in true }
        _ = try await replayTree(settled) { _ in true }
        #expect((agentFirstSeenAtPublication ?? Int.max) <= 3)
        #expect(fullPublications == 4)
        #expect(channel.listWorkspaceRequests == 4)
        #expect(channel.listPersonalRequests - personalBefore <= 2)
        #expect(channel.sidebarLayoutRequests - layoutBefore <= 2)
        await sync.bind(nil, macID: "mac")
    }

    @Test func notificationRefreshesOnceWithoutReloadingArrangement() async throws {
        let initial = #"{"ok":true,"data":{"workspace_revision":1,"registry_id":"r","workspaces":[{"id":1,"key":"one","name":"One","screens":[{"id":1,"panes":[{"id":1,"tabs":[{"surface":1,"kind":"pty","title":"Shell","notification":{"notification":9,"unread":false}}]}]}]}]}}"#
        let channel = ReplayDaemonChannel(snapshotBody: initial)
        defer { channel.finish() }
        let sync = WorkspaceSync(deviceID: "test", deviceName: "iPhone")
        let (ready, readyContinuation) = AsyncStream<DaemonTree>.makeStream()
        let (settled, settledContinuation) = AsyncStream<DaemonTree>.makeStream()
        defer { readyContinuation.finish(); settledContinuation.finish() }
        var fullPublications = 0
        var notifications = 0
        sync.onNotification = { _ in notifications += 1 }
        sync.onTree = { tree in
            fullPublications += 1
            if fullPublications == 2 { readyContinuation.yield(tree) }
            if fullPublications == 3 {
                // The row callback is an event-queue barrier after the refresh
                // has published and released its task. It catches a second
                // queued refresh without relying on a sleep to let it run.
                channel.emit(#"{"event":"title-changed","surface":1,"title":"notification-settled"}"#)
            }
        }
        sync.onRows = { tree, _, _ in settledContinuation.yield(tree) }
        await sync.bind(channel, macID: "mac")
        let baseline = try await replayTree(ready) { _ in true }
        #expect(baseline.notificationMarkers[1]?.unread == false)
        #expect(channel.listWorkspaceRequests == 2)
        let personalBefore = channel.listPersonalRequests
        let layoutBefore = channel.sidebarLayoutRequests
        #expect(personalBefore == 1)
        #expect(layoutBefore == 1)

        channel.replaceSnapshot(initial.replacingOccurrences(of: "\"unread\":false", with: "\"unread\":true"))
        channel.emit(#"{"event":"notification","notification":9,"surface":1,"source":"agent","preview":"Done"}"#)
        let updated = try await replayTree(settled) { tree in
            tree.workspaces.first?.tabs.first?.title == "notification-settled"
        }
        #expect(updated.notificationMarkers[1]?.unread == true)
        #expect(notifications == 1)
        #expect(fullPublications == 3)
        #expect(channel.listWorkspaceRequests == 3)
        #expect(channel.listPersonalRequests == personalBefore)
        #expect(channel.sidebarLayoutRequests == layoutBefore)
        await sync.bind(nil, macID: "mac")
    }

    @Test func setupFailureRecoversOnWorkspaceAddedWithoutAnotherBind() async throws {
        let channel = ReplayDaemonChannel(failIdentify: true)
        defer { channel.finish() }
        let sync = WorkspaceSync(deviceID: "test", deviceName: "iPhone")
        let (updates, continuation) = AsyncStream<DaemonTree>.makeStream()
        defer { continuation.finish() }
        sync.onTree = { continuation.yield($0) }
        sync.onRows = { tree, _, _ in continuation.yield(tree) }
        await sync.bind(channel, macID: "mac")
        #expect(sync.tree == nil)
        #expect(sync.lastError != nil)

        // A complete delta must trigger baseline recovery rather than silently
        // constructing a partial tree after the setup failed.
        channel.emit(#"{"event":"workspace-added","workspace":9,"workspace_revision":2,"registry_id":"r","entity":{"id":9,"key":"new","name":"New","screens":[]}}"#)
        let recovered = try await replayTree(updates) { tree in tree.workspaces.first?.id == "one" }
        #expect(recovered.workspaces.first?.tabs.first?.title == "snapshot-title")
        #expect(channel.listWorkspaceRequests == 2)
        #expect(sync.lastError == nil)
        await sync.bind(nil, macID: "mac")
    }
}

private enum ReplayWaitError: Error { case timedOut, streamEnded }

/// Event-driven wait with a real deadline. Cancellation ends the stream
/// iterator, so a failure cannot leave a continuation or polling task alive.
private func replayTree(_ updates: AsyncStream<DaemonTree>,
                        matching predicate: @escaping @Sendable (DaemonTree) -> Bool) async throws -> DaemonTree {
    try await replayValue(updates, matching: predicate)
}

private func replayValue<Value: Sendable>(_ updates: AsyncStream<Value>,
                                         matching predicate: @escaping @Sendable (Value) -> Bool) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            for await tree in updates where predicate(tree) { return tree }
            throw ReplayWaitError.streamEnded
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw ReplayWaitError.timedOut
        }
        defer { group.cancelAll() }
        guard let tree = try await group.next() else { throw ReplayWaitError.streamEnded }
        return tree
    }
}

/// A daemon channel that frames every response with a newline and can place
/// events on either side of the exact list response in the same read chunk.
/// Mutable state is protected by the lock, including the request count.
private final class ReplayDaemonChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let replayOnRequest: Int?
    private let captureRaceOnRequest: Int?
    private let holdSnapshotRequest: Int?
    private let onSnapshotHeld: (@Sendable () -> Void)?
    private var heldSnapshot: Data?
    private let failIdentify: Bool
    private var snapshotBody: String?
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var closed = false
    private var listCount = 0
    private var personalCount = 0
    private var layoutCount = 0
    var listWorkspaceRequests: Int { lock.withLock { listCount } }
    var listPersonalRequests: Int { lock.withLock { personalCount } }
    var sidebarLayoutRequests: Int { lock.withLock { layoutCount } }

    func replaceSnapshot(_ body: String) { lock.withLock { snapshotBody = body } }

    init(replayOnRequest: Int? = nil, failIdentify: Bool = false, snapshotBody: String? = nil, captureRaceOnRequest: Int? = nil,
         holdSnapshotRequest: Int? = nil, onSnapshotHeld: (@Sendable () -> Void)? = nil) {
        self.replayOnRequest = replayOnRequest
        self.captureRaceOnRequest = captureRaceOnRequest
        self.holdSnapshotRequest = holdSnapshotRequest
        self.onSnapshotHeld = onSnapshotHeld
        self.failIdentify = failIdentify
        self.snapshotBody = snapshotBody
    }

    func send(_ data: Data) async throws {
        for line in data.split(separator: 0x0A) {
            guard let request = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = request["id"] as? String else { continue }
            if let operation = request["operation"] as? String {
                if operation == "sidebar_layout.get" { lock.withLock { layoutCount += 1 } }
                push(Self.withID(id, body: #"{"ok":true,"result":{}}"#))
                continue
            }
            guard let command = request["cmd"] as? String else { continue }
            if command == "list-personal" { lock.withLock { personalCount += 1 } }
            if command == "list-workspaces" {
                let number = lock.withLock { listCount += 1; return listCount }
                let title: String
                if let captureRaceOnRequest, number > captureRaceOnRequest {
                    title = "newer-than-capture"
                } else {
                    title = replayOnRequest.map { number > $0 ? "after-snapshot" : "snapshot-title" } ?? "snapshot-title"
                }
                let snapshot = lock.withLock { snapshotBody } ?? Self.snapshot(title: title)
                if number == holdSnapshotRequest {
                    lock.withLock { heldSnapshot = Self.withID(id, body: snapshot) }
                    onSnapshotHeld?()
                } else if number == captureRaceOnRequest {
                    var batch = Data((#"{"event":"title-changed","surface":1,"title":"newer-than-capture"}"# + "\n").utf8)
                    batch.append(Self.withID(id, body: snapshot))
                    push(batch)
                } else if number == replayOnRequest {
                    var batch = Data((#"{"event":"title-changed","surface":1,"title":"stale-title"}"# + "\n").utf8)
                    batch.append(Data((#"{"event":"tab-added","workspace":1,"screen":1,"pane":1,"surface":2,"index":1,"entity":{"surface":2,"kind":"pty","title":"stale-add"}}"# + "\n").utf8))
                    batch.append(Self.withID(id, body: snapshot))
                    batch.append(Data((#"{"event":"title-changed","surface":1,"title":"after-snapshot"}"# + "\n").utf8))
                    push(batch)
                } else {
                    push(Self.withID(id, body: snapshot))
                }
            } else if command == "identify" && failIdentify {
                push(Self.withID(id, body: #"{"ok":false,"error":"setup failed"}"#))
            } else if command == "list-agents" {
                push(Self.withID(id, body: #"{"ok":true,"data":{"agents":[]}}"#))
            } else {
                push(Self.withID(id, body: #"{"ok":true,"data":{}}"#))
            }
        }
    }

    func emit(_ line: String) { push(Data((line + "\n").utf8)) }

    func emitBatch(_ lines: [String]) { push(Data((lines.joined(separator: "\n") + "\n").utf8)) }

    func releaseHeldSnapshot() {
        let reply = lock.withLock { let reply = heldSnapshot; heldSnapshot = nil; return reply }
        if let reply { push(reply) }
    }

    func receive() async throws -> Data? {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if !inbox.isEmpty { continuation.resume(returning: inbox.removeFirst()) }
                else if closed { continuation.resume(returning: nil) }
                else { waiter = continuation }
            }
        }
    }

    func close(code: String, reason: String) async { finish() }

    func finish() {
        lock.withLock {
            closed = true
            waiter?.resume(returning: nil)
            waiter = nil
        }
    }

    private func push(_ data: Data) {
        lock.withLock {
            guard !closed else { return }
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: data)
            } else {
                inbox.append(data)
            }
        }
    }

    private static func snapshot(title: String) -> String {
        #"{"ok":true,"data":{"workspace_revision":1,"registry_id":"r","workspaces":[{"id":1,"key":"one","name":"One","screens":[{"id":1,"panes":[{"id":1,"tabs":[{"surface":1,"kind":"pty","title":"\#(title)"},{"surface":2,"kind":"pty","title":"snapshot-tab"}]}]}]}]}}"#
    }

    private static func withID(_ id: String, body: String) -> Data {
        Data(("{\"id\":\"\(id)\"," + String(body.dropFirst()) + "\n").utf8)
    }
}
