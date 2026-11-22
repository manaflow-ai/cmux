import Foundation
import Testing
@testable import CmuxNextDaemon

/// One row per app path that sent a Cloud VM daemon (cmux-tui 7d177547949b,
/// `CloudVMDaemonGateTests`) a command it does not have. Each row names the
/// app call site and calls the `DaemonConnection` method that call site
/// calls, on a connection to that daemon.
@Suite(.timeLimit(.minutes(1))) struct CloudVMDaemonPathTests {
    struct Path: Sendable, CustomTestStringConvertible {
        let name: String
        let run: @Sendable (DaemonConnection) async throws -> Void
        var testDescription: String { name }
    }

    static let paths: [Path] = [
        Path(name: "TabHandlers+More.swift:77 palette.toggleTabUnread (ack-tab-notifications)") {
            _ = try await $0.acknowledgeNotifications(of: 3)
        },
        Path(name: "NotificationHandlers.swift:138 acknowledge: markAll, markOldest, toggleUnread, toggleRead, dismiss (ack-tab-notifications)") {
            _ = try await $0.acknowledgeNotifications(of: 3)
        },
        Path(name: "NotificationsPanelController.swift:131 panel reload (list-notifications)") {
            _ = try await $0.notificationLedger()
        },
        Path(name: "NotificationHandlers.swift:72 notificationCopy (list-notifications)") {
            _ = try await $0.notificationLedger(limit: 1)
        },
        Path(name: "TabGroupHandlers.swift:79 tabGroup.create (create-tab-group)") {
            _ = try await $0.createTabGroup(in: 4, tabs: [3], name: nil, color: "blue", transaction: "tx")
        },
        Path(name: "ScreenDragSession.swift:100 via ScreenCommands.swift:130 screen drag to a workspace (move-screen)") {
            _ = try await $0.moveScreen(5, to: nil, workspace: 1)
        },
        Path(name: "ScreenDragSession.swift:103,106 via ScreenCommands.swift:142 screen drag to a new workspace (move-screen)") {
            _ = try await $0.moveScreen(5, to: nil, newWorkspace: true)
        },
        Path(name: "TabMoves.swift:86 tab drag to a split (move-tab-to-split)") {
            _ = try await $0.moveTabToSplit(3, pane: 4, edge: .right)
        },
        Path(name: "TabMoves.swift:111 tab drag to a new column (move-tab-to-column)") {
            _ = try await $0.moveTabToColumn(3, target: .pane(4), width: 0.5)
        },
        Path(name: "TabMoves.swift:176 tab drag to a new workspace (move-tab-to-new-workspace)") {
            _ = try await $0.moveTabToNewWorkspace(3)
        },
    ]

    @Test(arguments: paths) func thePathSendsTheCloudVMDaemonNoCommandItDoesNotHave(_ path: Path) async throws {
        let unknown = CloudVMDaemonGateTests.Refused()
        let server = try FakeDaemonServer(handler: CloudVMDaemonGateTests.vmDaemon(unknown: unknown))
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        try? await path.run(connection)
        #expect(unknown.names.withLock { $0 } == [], "\(path.name) sent a command the Cloud VM daemon does not have")
        await connection.close()
    }
}
