@testable import CmuxMobileShell
import CmuxMobileSSH
import Foundation
import Testing

/// The phone's grouped tmux sessions under an abrupt disconnect, on a
/// PRIVATE tmux server (`-L`) so the user's sessions are never at risk.
///
/// With `destroy-unattached on`, killing the app while two tmux workspaces
/// were attached crashed tmux 3.7c (SIGSEGV in `server_client_get_pane` from
/// `server_client_lost`) and destroyed every session on the server. The
/// shell repro `artifacts/dssh/v2/tmux-crash-fix/tmux-grouped-crash-repro.sh
/// old` crashes 8 of 10 runs; this test drives the app's provider through
/// the same drop 20 times. Run with `CMUX_SSH_LAB=/tmp/cmux-ssh-lab`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] != nil))
struct MobileSSHTmuxGroupedSessionLabTests {
    static let tmuxPath = "/opt/homebrew/bin/tmux"
    let lab = ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] ?? ""

    @MainActor final class Seeded { var count = 0 }

    @Test(.timeLimit(.minutes(5))) func abruptDropWithTwoWorkspacesAttachedKeepsTheServer() async throws {
        let socket = "cmux-lab-grouped-\(UUID().uuidString.prefix(8).lowercased())"
        defer { Self.tmux(socket, "kill-server") }
        Self.tmux(socket, "new-session", "-d", "-s", "laptop", "-x", "80", "-y", "24")
        Self.tmux(socket, "new-session", "-d", "-s", "ws", "-x", "80", "-y", "24")

        for iteration in 1...20 {
            let connection = try await connect()
            let provider = MobileSSHTmuxProvider(connection: connection, tmuxPath: Self.tmuxPath, socketName: socket)
            // Listing collects what the previous iteration's drop left behind.
            let workspaces = try await provider.listWorkspaces()
            #expect(Self.groupedSessions(socket).isEmpty, "iteration \(iteration): stale grouped sessions survived collection")

            let seeded = Seeded()
            var attached: [any MobileSSHAttachedTerminal] = []
            for session in ["laptop", "ws"] {
                let terminal = try #require(workspaces.first { $0.id == session }?.terminals.first)
                attached.append(try await provider.attach(terminalID: terminal.id, columns: 66, rows: 52) { event in
                    if case .snapshot = event { seeded.count += 1 }
                })
            }
            try await Self.waitUntil { seeded.count == 2 }
            #expect(Self.groupedSessions(socket).filter { $0.attached }.count == 2)

            // The app is killed: both channels drop at once, no graceful close.
            await connection.close()
            try await Self.waitUntil { Self.phoneClientCount(socket) == 0 }
            #expect(Self.tmuxStatus(socket, "has-session", "-t", "=laptop") == 0, "iteration \(iteration): tmux server died")
            #expect(Self.tmuxStatus(socket, "has-session", "-t", "=ws") == 0, "iteration \(iteration): tmux server died")
            #expect(Self.groupedSessions(socket).count == 2, "iteration \(iteration): grouped sessions are left for collection")
            _ = attached
        }

        let connection = try await connect()
        _ = try await MobileSSHTmuxProvider(connection: connection, tmuxPath: Self.tmuxPath, socketName: socket).listWorkspaces()
        #expect(Self.groupedSessions(socket).isEmpty)
        await connection.close()
    }

    /// A graceful close (last pane detached) kills the phone's grouped
    /// session itself; the user's session and windows stay.
    @Test(.timeLimit(.minutes(2))) func gracefulDetachKillsOnlyTheGroupedSession() async throws {
        let socket = "cmux-lab-grouped-\(UUID().uuidString.prefix(8).lowercased())"
        defer { Self.tmux(socket, "kill-server") }
        Self.tmux(socket, "new-session", "-d", "-s", "laptop", "-x", "80", "-y", "24")
        let connection = try await connect()
        defer { Task { await connection.close() } }
        let provider = MobileSSHTmuxProvider(connection: connection, tmuxPath: Self.tmuxPath, socketName: socket)
        let terminal = try #require(try await provider.listWorkspaces().first?.terminals.first)
        let seeded = Seeded()
        let attachment = try await provider.attach(terminalID: terminal.id, columns: 80, rows: 24) { event in
            if case .snapshot = event { seeded.count += 1 }
        }
        try await Self.waitUntil { seeded.count == 1 }
        #expect(Self.groupedSessions(socket).count == 1)
        // tmux does not destroy it on its own (no destroy-unattached).
        let grouped = try #require(Self.groupedSessions(socket).first).name
        #expect(Self.tmux(socket, "show-options", "-v", "-t", "=" + grouped + ":", "destroy-unattached") == "off")
        await attachment.detach()
        try await Self.waitUntil { Self.groupedSessions(socket).isEmpty }
        #expect(Self.tmuxStatus(socket, "has-session", "-t", "=laptop") == 0)
    }

    // MARK: Helpers

    func connect() async throws -> SSHConnection {
        let key = try SSHPrivateKeyParser.parse(try String(contentsOfFile: "\(lab)/client_ed25519", encoding: .utf8)).key
        return try await SSHConnection.connect(
            to: SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()),
            credentials: [.privateKey(key)],
            hostKeyVerifier: AcceptingVerifier()
        )
    }

    static func groupedSessions(_ socket: String) -> [(name: String, attached: Bool)] {
        tmux(socket, "list-sessions", "-F", "#{session_attached}:#{session_name}")
            .split(separator: "\n")
            .compactMap { line in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let name = String(line[line.index(after: colon)...])
                guard name.contains(MobileSSHTmuxControlClient.groupedSessionMarker) else { return nil }
                return (name, line[..<colon] != "0")
            }
    }

    /// Clients still attached to a phone grouped session (0 once the server
    /// has processed both drops, or when it is gone).
    static func phoneClientCount(_ socket: String) -> Int {
        tmux(socket, "list-clients", "-F", "#{client_session}")
            .split(separator: "\n")
            .filter { $0.contains(MobileSSHTmuxControlClient.groupedSessionMarker) }
            .count
    }

    @discardableResult
    static func tmux(_ socket: String, _ arguments: String...) -> String {
        run(socket, arguments).output
    }

    static func tmuxStatus(_ socket: String, _ arguments: String...) -> Int32 {
        run(socket, arguments).status
    }

    private static func run(_ socket: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["-L", socket] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func waitUntil(timeout: Duration = .seconds(15), _ predicate: @MainActor () -> Bool) async throws {
        try await MobileSSHComputersLabTests.waitUntil(timeout: timeout, predicate)
    }
}
