import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Leo, 2026-11-09: "the other thing is that for some reason the dot isn't disappearing in my
/// case... but i guess the current nightly still hasn't fixed/restarted the service?" Mark as Read
/// and Mark All Notifications as Read made on the phone while the Mac's daemon restarts reach the
/// Mac once it is back, against a mock Mac whose daemon goes quiet and then closes the channel.
@MainActor
@Suite struct PhoneReadsStickTests {
    final class Mac: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [[String: Any]] = []
        private var quiet = false
        func append(_ object: [String: Any]) { lock.withLock { lines.append(object) } }
        /// The daemon restarting: a write gets no answer.
        var isQuiet: Bool {
            get { lock.withLock { quiet } }
            set { lock.withLock { quiet = newValue } }
        }
        var mutations: [[String: Any]] {
            lock.withLock { lines }.filter { line in
                guard let cmd = line["cmd"] as? String else { return false }
                return !["list-workspaces", "subscribe", "set-client-info", "identify", "list-agents", "list-personal"].contains(cmd)
            }
        }
        var commands: [String] { mutations.compactMap { $0["cmd"] as? String } }

        /// wk1, marked unread, with tab s5 unread at notification 9 and s6 quiet.
        static let tree = #"{"workspaces":[{"id":1,"key":"wk1","name":"main","marked_unread":true,"unread_count":1,"screens":[{"id":5,"name":"","active":true,"active_pane":1,"panes":[{"id":1,"name":"","active_tab":0,"tabs":[{"surface":5,"kind":"pty","title":"codex","terminal_id":"term_a","notification":{"notification":9,"unread":true}},{"surface":6,"kind":"pty","title":"zsh","terminal_id":"term_b"}]}]}]}]}"#

        func link() -> MockMacLink {
            MockMacLink { _, data in
                data.split(separator: 0x0A).compactMap { request -> Data? in
                    guard let object = try? JSONSerialization.jsonObject(with: Data(request)) as? [String: Any],
                          let id = object["id"] as? String else { return nil }
                    self.append(object)
                    let cmd = object["cmd"] as? String ?? ""
                    let line: String
                    switch cmd {
                    case "list-workspaces":
                        line = #"{"id":"\#(id)","ok":true,"data":\#(Self.tree)}"#
                    case "list-agents":
                        line = #"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#
                    case "set-workspace-metadata", "ack-tab-notifications":
                        if self.isQuiet { return nil }
                        line = #"{"id":"\#(id)","ok":true,"data":{}}"#
                    default:
                        line = #"{"id":"\#(id)","ok":true,"data":{}}"#
                    }
                    return Data(line.utf8) + Data([0x0A])
                }
            }
        }
    }

    func connected(_ mac: Mac) async throws -> (LiveWorkspaceCreationBackend, WorkspaceSync) {
        let controller = LinkController(transport: .wireGuard, dialer: MockDialer(fail: false), accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://x")!, teamID: "t", deviceID: "d", macDeviceID: $0) }
        controller.send(.target(LinkMachine.Target(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<200 where !controller.phase.isConnected { await Task.yield() }
        let sync = WorkspaceSync(deviceID: "d", deviceName: "iPhone")
        await sync.bind(try await mac.link().openChannel(service: "daemon", args: [:]), macID: "m")
        return (LiveWorkspaceCreationBackend(sync: sync, link: controller), sync)
    }

    /// Waits up to `seconds` of real time for `condition` (a retry is spaced in real time).
    static func waitUntil(seconds: Double = 3, _ condition: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// The daemon restarts under a write: its channel goes quiet and closes, and the Mac comes
    /// back on a new channel a moment later.
    func restart(_ mac: Mac, _ sync: WorkspaceSync, sent command: String) async throws {
        await Self.waitUntil { mac.commands.contains(command) }
        await sync.daemon?.close()
        await sync.bind(nil, macID: "m")
        try await Task.sleep(for: .milliseconds(300))
        mac.isQuiet = false
        await sync.bind(try await mac.link().openChannel(service: "daemon", args: [:]), macID: "m")
    }

    @Test func markAsReadMadeWhileTheDaemonRestartsReachesItOnceItIsBack() async throws {
        let mac = Mac()
        let (backend, sync) = try await connected(mac)
        let workspace = try #require(sync.tree?.workspaces.first { $0.id == "wk1" })
        #expect(workspace.hasUnread)

        mac.isQuiet = true
        let read = Task { try await backend.setUnread(workspace, false) }
        try await restart(mac, sync, sent: "set-workspace-metadata")
        try await read.value

        let writes = mac.mutations.filter { $0["cmd"] as? String == "set-workspace-metadata" }
        #expect(writes.count >= 2, "the unanswered write went again")
        #expect(writes.allSatisfy { $0["marked_unread"] as? Bool == false && $0["key"] as? String == "wk1" })
        let acks = mac.mutations.filter { $0["cmd"] as? String == "ack-tab-notifications" }
        #expect(acks.map { $0["surface"] as? Int } == [5])
    }

    @Test func markAllAsReadMadeWhileTheDaemonRestartsReachesItOnceItIsBack() async throws {
        let mac = Mac()
        let (backend, sync) = try await connected(mac)

        mac.isQuiet = true
        let read = Task { try await backend.markAllNotificationsRead(on: "m") }
        try await restart(mac, sync, sent: "ack-tab-notifications")
        #expect(try await read.value == 1)

        // The first ack went unanswered; the second reaches the Mac that came back.
        await Self.waitUntil { mac.commands.filter { $0 == "ack-tab-notifications" }.count >= 2 }
        let acks = mac.mutations.filter { $0["cmd"] as? String == "ack-tab-notifications" }
        #expect(acks.count == 2)
        #expect(acks.allSatisfy { $0["surface"] as? Int == 5 })
    }

    /// Review finding: Mark All made while the Mac's daemon channel is unbound (reconnecting)
    /// still takes that Mac, and its reads reach it once it is back.
    @Test func markAllAsReadMadeWhileReconnectingReachesTheMacOnceItIsBack() async throws {
        let mac = Mac()
        let (backend, sync) = try await connected(mac)
        await sync.daemon?.close()
        await sync.bind(nil, macID: "m")
        #expect(backend.canMarkAllNotificationsRead(on: "m"))
        #expect(try await backend.markAllNotificationsRead(on: "m") == 1)
        await sync.bind(try await mac.link().openChannel(service: "daemon", args: [:]), macID: "m")
        await Self.waitUntil { mac.commands.contains("ack-tab-notifications") }
        #expect(mac.mutations.filter { $0["cmd"] as? String == "ack-tab-notifications" }.map { $0["surface"] as? Int } == [5])
    }

    /// Review finding: a daemon that restarted numbers its markers anew; the notification's time
    /// still names the one the person read, and a newer one is left unread.
    @Test func aRenumberedMarkerIsStillTheNotificationRead() throws {
        let posted = Date(timeIntervalSince1970: 1_000)
        let read = LiveWorkspaceCreationBackend.UnreadMark(
            surface: 5, marker: DaemonTree.NotificationMarker(notification: 300, unread: true, createdAt: posted))
        let empty = try DaemonTree(reply: Data(#"{"ok":true,"data":{"workspaces":[]}}"#.utf8), macID: "m")
        func tree(_ marker: DaemonTree.NotificationMarker) -> DaemonTree {
            var tree = empty
            tree.notificationMarkers[5] = marker
            return tree
        }
        let renumbered = tree(DaemonTree.NotificationMarker(notification: 256, unread: true, createdAt: posted))
        #expect(LiveWorkspaceCreationBackend.stillUnread([read], in: renumbered) == [5])
        let newer = tree(DaemonTree.NotificationMarker(notification: 257, unread: true, createdAt: posted.addingTimeInterval(5)))
        #expect(LiveWorkspaceCreationBackend.stillUnread([read], in: newer).isEmpty)
        let done = tree(DaemonTree.NotificationMarker(notification: 256, unread: false, createdAt: posted))
        #expect(LiveWorkspaceCreationBackend.stillUnread([read], in: done).isEmpty)
    }
}
