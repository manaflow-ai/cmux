import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// A workspace create writes the same bytes to the daemon's disk at any session size (#32408, R-DURABILITY S-WS).
///
/// The app saved its window state as one document (`WindowStateStore.update`, `put-frontend-projection`), and each
/// window record lists every workspace of its window: a create rewrote about 50 KB at 500 workspaces, twice. The WAL
/// checkpoint then ran its fsync all the time (5301 of 5308 samples at workspace 440 of the 512 classic import, step
/// bad641b4) and every write waited behind it. The test makes workspaces with `create-workspace` (no terminal, so no
/// PTY), lets the app place each one in its window and store the window state (`flushSaves`), and reads the registry's
/// WAL frame bytes (`server-stats` `write_path.registry_wal_frame_bytes`) around 100 creates, at 50 and at 500
/// workspaces in the window. The bytes per create, the daemon's own and the app's window-state save together, must be
/// equal within 10 %.
@MainActor @Suite(.serialized, .timeLimit(.minutes(15)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct WindowStateBytesPerCreateTests {
    /// `server-stats` with the `write_path` section.
    struct ServerStatsRequest: DaemonRequest {
        typealias Response = Stats
        static let command = "server-stats"
        let include = ["write_path"]

        struct Stats: Decodable, Sendable {
            let writePath: WritePath?
            enum CodingKeys: String, CodingKey { case writePath = "write_path" }
        }

        struct WritePath: Decodable, Sendable {
            let registryWalFrameBytes: UInt64?
            enum CodingKeys: String, CodingKey { case registryWalFrameBytes = "registry_wal_frame_bytes" }
        }
    }

    static let creates = 100

    @Test func aCreateWritesTheSameBytesAt50And500Workspaces() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let window = try #require(services.windows.active?.state.id)
            let small = try await Self.bytesPerCreate(services, connection, window: window, workspaces: 50)
            let large = try await Self.bytesPerCreate(services, connection, window: window, workspaces: 500)
            print("WINDOW-STATE-BYTES per_create small=\(small) (50 workspaces) large=\(large) (500 workspaces) ratio=\(Double(large) / Double(max(small, 1)))")
            #expect(Double(large) <= Double(small) * 1.10,
                    "one create wrote \(large) bytes at 500 workspaces and \(small) at 50: the bytes grow with the session")
        }
    }

    /// Fills the window to `workspaces`, then makes `creates` more one at a time, each placed in the window and its
    /// window state stored before the next; the mean registry WAL bytes of those creates.
    static func bytesPerCreate(_ services: AppServices, _ connection: DaemonConnection, window: String,
                               workspaces: Int) async throws -> UInt64 {
        let store = services.daemon.store
        let windows = services.windows
        let fill = workspaces - (windows.registry.value.window(window)?.workspaceIDs.count ?? 0)
        if fill > 0 {
            for _ in 0..<fill { _ = try await connection.createWorkspace() }
            try await PinnedPageTests.until({ (windows.registry.value.window(window)?.workspaceIDs.count ?? 0) >= workspaces },
                                            within: .seconds(120),
                                            report: { "the window lists \(windows.registry.value.window(window)?.workspaceIDs.count ?? 0) of \(workspaces)" })
            await windows.recordSaver.flushSaves()
        }
        let before = try await Self.walBytes(connection)
        var daemonPart: UInt64 = 0
        for _ in 0..<creates {
            // DIAG (#32408): the create's own commit (read at its reply), apart from what the app writes after it.
            let b0 = try await Self.walBytes(connection)
            let made = try await connection.createWorkspace().key.rawValue
            daemonPart += try await Self.walBytes(connection) - b0
            try await PinnedPageTests.until({ store.workspace(id: made) != nil && windows.registry.value.owner(of: made) == window },
                                            within: .seconds(30), report: { "workspace \(made) is not listed in its window" })
            // The window state of this create is stored before the next one starts.
            await windows.recordSaver.flushSaves()
        }
        let after = try await Self.walBytes(connection)
        print("DIAG-BYTES at=\(workspaces) total_per_create=\((after - before) / UInt64(creates)) create_commit=\(daemonPart / UInt64(creates)) app_after=\((after - before - daemonPart) / UInt64(creates))")
        return (after - before) / UInt64(creates)
    }

    static func walBytes(_ connection: DaemonConnection) async throws -> UInt64 {
        let stats = try await connection.request(ServerStatsRequest())
        return try #require(stats.writePath?.registryWalFrameBytes, "the daemon reports no registry_wal_frame_bytes")
    }
}
