import CmuxNextTrace
import CmuxNextWakeups
import Testing
@testable import CmuxNextDaemon

/// The local daemon's store names the daemon in the crash-key page: its connection state,
/// pid and Ghostty commit on each connection change, and the workspace count on each change of the tree.
@MainActor
struct DaemonCrashKeyPageTests {
    @Test func eachConnectionChangeNamesTheDaemon() {
        let keys = CrashKeySlots(), page = CrashKeyPage(identity: .init(role: .app))
        keys.page.attach(page)
        let store = DaemonStore(crashKeys: keys)
        let identity = DaemonIdentity(ghosttyCommit: "0123456789abcdef0123456789abcdef01234567", pid: 4321,
                                      generation: "g1")
        _ = DaemonConnectionChange.connected(identity, nil).apply(to: store)
        #expect(page.value(.daemonState) == 2)
        #expect(page.value(.daemonPID) == 4321)
        #expect(page.value(.ghosttyCommit) == 0x0123_4567_89AB_CDEF)
        _ = DaemonConnectionChange.disconnected("socket closed").apply(to: store)
        #expect(page.value(.daemonState) == 3)
        #expect(page.value(.daemonPID) == 0, "a disconnected daemon kept its pid")
        #expect(page.value(.ghosttyCommit) == 0x0123_4567_89AB_CDEF, "the commit went with the connection")
        store.markFailed("incompatible")
        #expect(page.value(.daemonState) == 4)
    }

    @Test func theWorkspaceCountFollowsTheTree() {
        let keys = CrashKeySlots(), page = CrashKeyPage(identity: .init(role: .app))
        keys.page.attach(page)
        let store = DaemonStore(crashKeys: keys)
        store.apply(snapshot: DaemonTree(workspaces: (1 ... 5).map(Self.workspace)))
        #expect(page.value(.workspaceCount) == 4)
        store.apply(snapshot: DaemonTree(workspaces: [Self.workspace(1)]))
        #expect(page.value(.workspaceCount) == 1)
    }

    private static func workspace(_ id: UInt64) -> WorkspaceSnapshot {
        let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: [TabSnapshot(surface: SurfaceID(rawValue: id))])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, name: "w\(id)",
                                 screens: [ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])])
    }
}
