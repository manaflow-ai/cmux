import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// a316's report (2026-10-20): Pin/Unpin Workspace ran on subagent workspaces in the Chief's own session
/// (`cmux-chief-…`), but their daemon's `pinned` flag stayed false. Pin must reach the workspace's own
/// daemon in any session, not only the home daemon's sidebar document.
@MainActor @Suite struct WorkspacePinFlagsTests {
    private static func daemon(session: String, workspace id: UInt64, key: String, pinned: Bool = false) throws -> DaemonService {
        let daemon = DaemonService()
        let json = #"{"app":"cmux-tui","protocol":1,"session":"\#(session)","generation":"g1"}"#
        daemon.store.connectionState = .connected(try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8)))
        daemon.store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: WorkspaceKey(rawValue: key), name: key, pinned: pinned),
        ]))
        return daemon
    }

    private struct Sent: Equatable {
        let daemon: ObjectIdentifier
        let key: String
        let pinned: Bool
    }

    private static func flags(_ daemons: [DaemonService], into sent: @escaping (Sent) -> Void) -> WorkspacePinFlags {
        WorkspacePinFlags(owner: { id in
            daemons.lazy.compactMap { daemon in daemon.store.workspace(id: id).map { ($0, daemon) } }.first
        }, supportsPin: { _ in true }, send: { daemon, key, pinned in
            sent(Sent(daemon: ObjectIdentifier(daemon), key: key.rawValue, pinned: pinned))
        })
    }

    @Test func pinReachesTheWorkspacesOwnDaemonInEverySession() throws {
        let home = try Self.daemon(session: "cmux-app", workspace: 1, key: "home-ws")
        let chief = try Self.daemon(session: "cmux-chief-2e448bc2", workspace: 2, key: "chief-ws")
        let ids = [home, chief].flatMap { $0.store.workspaces.map(\.id) }
        var sent: [Sent] = []
        Self.flags([home, chief]) { sent.append($0) }.mirror(ids, pinned: true)
        #expect(sent.contains(Sent(daemon: ObjectIdentifier(chief), key: "chief-ws", pinned: true)), "the Chief session's workspace was not pinned on its daemon")
        #expect(sent.contains(Sent(daemon: ObjectIdentifier(home), key: "home-ws", pinned: true)))
    }

    @Test func aFlagAlreadySetIsNotSentAgain() throws {
        let chief = try Self.daemon(session: "cmux-chief-2e448bc2", workspace: 2, key: "chief-ws", pinned: true)
        var sent: [Sent] = []
        let flags = Self.flags([chief]) { sent.append($0) }
        flags.mirror(chief.store.workspaces.map(\.id), pinned: true)
        #expect(sent.isEmpty)
        flags.mirror(chief.store.workspaces.map(\.id), pinned: false)
        #expect(sent == [Sent(daemon: ObjectIdentifier(chief), key: "chief-ws", pinned: false)], "Unpin did not clear the flag")
    }
}
