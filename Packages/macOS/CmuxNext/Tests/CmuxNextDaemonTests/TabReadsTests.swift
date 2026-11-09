@testable import CmuxNextDaemon
import Foundation
import Testing

/// Leo, 2026-11-09: "the other thing is that for some reason the dot isn't disappearing in my case... but i guess the
/// current nightly still hasn't fixed/restarted the service?". His nightly's daemon was still restoring, so every
/// `ack-tab-notifications` failed ("not connected") and the read rolled back: the dot came back after every look.
/// A read the person made now stays while the daemon is down or restoring and goes again until it answers; only the
/// daemon's refusal, or a newer notification in its record, shows the dot again (``TabReads``).
@MainActor
struct TabReadsTests {
    static func tree(unread: Bool, notification: UInt64 = 4) -> DaemonTree {
        let marker = TabNotification(notification: NotificationID(rawValue: notification), unread: unread, level: .info, source: "agent")
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7", notification: marker)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])])
    }

    static func unreadTab() throws -> (DaemonStore, TabModel, TabReads) {
        let store = DaemonStore()
        store.apply(snapshot: tree(unread: true))
        let tab = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        #expect(tab.showsUnread)
        let reads = TabReads()
        reads.pause = { _ in }
        return (store, tab, reads)
    }

    /// What the daemon says to each try, in order: down, restoring (no answer in time), then `last`.
    static let down: [any Error] = [DaemonError.notConnected, DaemonError.notConnected, DaemonError.timedOut("ack-tab-notifications"),
                                    DaemonError.timedOut("ack-tab-notifications"), DaemonError.connectionClosed(reason: "restarting")]

    /// The daemon is down, then restoring, then answers: the dot goes once and never comes back, and the read reaches
    /// the daemon once it can (the tries before it went again, never rolled back).
    @Test func aReadStaysWhileTheDaemonIsDownAndReachesItOnReconnect() async throws {
        let (store, tab, reads) = try Self.unreadTab()
        var tries = 0, shownAtATry = 0, surfaces: [SurfaceID] = []
        let sent = try #require(reads.readNotification(of: tab) { surface in
            tries += 1
            if tab.showsUnread { shownAtATry += 1 }
            if tries <= Self.down.count { throw Self.down[tries - 1] }
            surfaces.append(surface)
        })
        #expect(!tab.showsUnread, "the read did not show at once")
        await sent.value
        #expect(tries == Self.down.count + 1)
        #expect(shownAtATry == 0, "the dot came back while the daemon was down")
        #expect(surfaces == [tab.surface], "the read never reached the daemon once it came back")
        #expect(!tab.showsUnread)
        #expect(tab.rollbacks.warnings.isEmpty)
        // The daemon's echo: the notification is read.
        store.apply(snapshot: Self.tree(unread: false))
        #expect(!tab.showsUnread)
    }

    /// The daemon comes back and refuses the read: only then does the dot show again.
    @Test func onlyTheDaemonsRefusalShowsTheDotAgain() async throws {
        let (_, tab, reads) = try Self.unreadTab()
        var tries = 0
        let sent = try #require(reads.readNotification(of: tab) { (_: SurfaceID) in
            tries += 1
            if tries <= Self.down.count { throw Self.down[tries - 1] }
            throw DaemonError.command(cmd: "ack-tab-notifications", message: "refused", code: "notification.refused")
        })
        await sent.value
        #expect(tries == Self.down.count + 1)
        #expect(tab.showsUnread, "a refused read stayed hidden")
    }

    /// While the daemon was away its record got a newer notification: the person has not seen it, so it shows, and the
    /// old read is not sent again (it would read the new one too).
    @Test func aNewerNotificationShowsAndEndsTheOldRead() async throws {
        let (store, tab, reads) = try Self.unreadTab()
        var tries = 0
        let sent = try #require(reads.readNotification(of: tab) { (_: SurfaceID) in
            tries += 1
            if tries == 2 { store.apply(snapshot: Self.tree(unread: true, notification: 5)) }
            throw DaemonError.notConnected
        })
        await sent.value
        #expect(tries == 2, "the old read went on after a newer notification arrived")
        #expect(tab.showsUnread)
    }

    /// The daemon comes back with the same unread notification (it never heard the read): the read stands and is sent.
    @Test func theSameNotificationAfterAReconnectStaysRead() async throws {
        let (store, tab, reads) = try Self.unreadTab()
        var tries = 0
        let sent = try #require(reads.readNotification(of: tab) { (_: SurfaceID) in
            tries += 1
            if tries == 2 { store.apply(snapshot: Self.tree(unread: true)) }
            if tries < 3 { throw DaemonError.notConnected }
        })
        await sent.value
        #expect(tries == 3)
        #expect(!tab.showsUnread, "the reconnect's tree brought the read dot back")
    }

    /// A key, a click and a look while the read waits for the daemon send nothing more: one write per read.
    @Test func aWaitingReadIsSentOnce() async throws {
        let (_, tab, reads) = try Self.unreadTab()
        var tries = 0
        let first = try #require(reads.readNotification(of: tab) { (_: SurfaceID) in
            tries += 1
            if tries < 3 { throw DaemonError.notConnected }
        })
        for _ in 0..<20 { #expect(reads.readNotification(of: tab) { (_: SurfaceID) in Issue.record("a second write of the same read") } == nil) }
        await first.value
        #expect(tries == 3)
    }

    /// Mark as Unread's clear stays while the daemon is down and settles on the record's echo.
    @Test func aMarkClearStaysWhileTheDaemonIsDown() async throws {
        let (_, tab, reads) = try Self.unreadTab()
        tab.applyState(SessionStateMirror.TabRecord(markedUnread: true), progress: nil)
        #expect(tab.markedUnread)
        var tries = 0, markedAtATry = 0
        await reads.clearMarkedUnread(of: tab) {
            tries += 1
            if tab.markedUnread { markedAtATry += 1 }
            if tries <= Self.down.count { throw Self.down[tries - 1] }
        }.value
        #expect(markedAtATry == 0, "the mark came back while the daemon was down")
        #expect(!tab.markedUnread)
        tab.applyState(SessionStateMirror.TabRecord(markedUnread: false), progress: nil)
        #expect(!tab.markedUnread)
    }

    /// An agent's mark cleared while the daemon is down stays cleared; a refusal brings it back.
    @Test func anAttentionClearStaysUntilRefused() async throws {
        let (_, tab, reads) = try Self.unreadTab()
        let mark = TabAttention(reason: "approve", atMs: 1, requestID: "req-1")
        tab.applyState(SessionStateMirror.TabRecord(attention: mark), progress: nil)
        let request = try #require(tab.expectAttentionClear())
        var tries = 0, shownAtATry = 0
        await reads.clearAttention(request, of: tab) {
            tries += 1
            if tab.attention != nil { shownAtATry += 1 }
            if tries <= Self.down.count { throw Self.down[tries - 1] }
            throw DaemonError.command(cmd: "tab.update", message: "refused", code: nil)
        }.value
        #expect(shownAtATry == 0)
        #expect(tab.attention == mark, "a refused clear stayed hidden")
    }
}
