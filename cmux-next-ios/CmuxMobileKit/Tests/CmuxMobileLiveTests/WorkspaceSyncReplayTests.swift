import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

@MainActor
@Suite struct WorkspaceSyncReplayTests {
    private static let snapshot = #"{"ok":true,"data":{"workspace_revision":1,"registry_id":"r","workspaces":[{"id":1,"key":"one","name":"One","screens":[{"id":1,"panes":[{"id":1,"tabs":[{"surface":1,"kind":"pty","title":"before"}]}]}]}]}}"#

    @Test func eventsReplayedWithSnapshotAreDiscarded() async throws {
        let channel = ReplayDaemonChannel(snapshot: Self.snapshot, replayTitle: "stale")
        let sync = WorkspaceSync(deviceID: "test", deviceName: "iPhone")
        await sync.bind(channel, macID: "mac")

        #expect(sync.tree?.workspaces.first?.tabs.first?.title == "before")
        #expect(sync.tree?.workspaces.first?.tabs.count == 1)
        await sync.bind(nil, macID: "mac")
    }

    @Test func setupFailureStillConsumesEventsAndRecoversWithSnapshot() async throws {
        let channel = ReplayDaemonChannel(snapshot: Self.snapshot, failIdentify: true)
        let sync = WorkspaceSync(deviceID: "test", deviceName: "iPhone")
        await sync.bind(channel, macID: "mac")
        #expect(sync.tree == nil)

        channel.emit(#"{"event":"tree-changed"}"#)
        for _ in 0..<200 where sync.tree == nil { await Task.yield() }

        #expect(sync.tree?.workspaces.first?.tabs.first?.title == "before")
        #expect(channel.listWorkspaceRequests >= 2)
        await sync.bind(nil, macID: "mac")
    }
}

/// A controllable daemon channel. It emits a title event before the snapshot
/// reply to model subscribe-before-list replay, and can fail setup while still
/// leaving the event stream alive.
private final class ReplayDaemonChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let snapshot: Data
    private let replayTitle: String?
    private let failIdentify: Bool
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var closed = false
    private(set) var listWorkspaceRequests = 0

    init(snapshot: String, replayTitle: String? = nil, failIdentify: Bool = false) {
        self.snapshot = Data(snapshot.utf8)
        self.replayTitle = replayTitle
        self.failIdentify = failIdentify
    }

    func send(_ data: Data) async throws {
        for line in data.split(separator: 0x0A) {
            guard let request = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = request["id"] as? String,
                  let command = request["cmd"] as? String else { continue }
            if command == "list-workspaces" {
                lock.withLock { listWorkspaceRequests += 1 }
                if let replayTitle, lock.withLock({ listWorkspaceRequests == 1 }) {
                    push(#"{"event":"title-changed","surface":1,"title":"#(replayTitle)"}"#)
                }
                push(Self.withID(id, body: snapshot))
            } else if command == "identify" && failIdentify {
                push(Self.withID(id, body: #"{"ok":false,"error":"setup failed"}"#))
            } else if command == "list-agents" {
                push(Self.withID(id, body: #"{"ok":true,"data":{"agents":[]}}"#))
            } else {
                push(Self.withID(id, body: #"{"ok":true,"data":{}}"#))
            }
        }
    }

    func emit(_ line: String) {
        push(Data((line + "\n").utf8))
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

    func close(code: String, reason: String) async {
        lock.withLock {
            closed = true
            waiter?.resume(returning: nil)
            waiter = nil
        }
    }

    private func push(_ data: Data) {
        lock.withLock {
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: data)
            } else {
                inbox.append(data)
            }
        }
    }

    private static func withID(_ id: String, body: String) -> Data {
        Data(("{\"id\":\"\(id)\"," + String(body.dropFirst()) + "\n").utf8)
    }
}
