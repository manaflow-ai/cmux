internal import CmuxMobileSSH
internal import CmuxMobileSupport
import Foundation

/// One workspace on an SSH computer, in host-local ids.
struct MobileSSHWorkspace: Equatable, Sendable {
    var id: String
    var name: String
    var terminals: [MobileSSHTerminal]
}

struct MobileSSHTerminal: Equatable, Sendable {
    var id: String
    var name: String
}

/// A live terminal attachment. Output flows through the callback given to
/// ``MobileSSHWorkspaceProvider/attach``; this handle carries input and size.
@MainActor
protocol MobileSSHAttachedTerminal: AnyObject {
    func write(_ data: Data) async
    func resize(columns: Int, rows: Int) async
    /// Leaves the remote session running (persistent modes) or ends it (plain).
    func detach() async
}

/// Output from an attachment, in order.
enum MobileSSHAttachEvent: Sendable {
    /// Replace the local screen with this snapshot (cmux-tui `vt-state`).
    case snapshot(Data)
    case output(Data)
    /// The remote side ended (shell exited, session killed, connection lost).
    case ended
}

/// How one persistence mode lists, creates, and attaches workspaces (PRD D9, D22).
@MainActor
protocol MobileSSHWorkspaceProvider: AnyObject {
    func listWorkspaces() async throws -> [MobileSSHWorkspace]
    func createWorkspace() async throws -> MobileSSHWorkspace
    func closeWorkspace(id: String) async throws
    func attach(
        terminalID: String,
        columns: Int,
        rows: Int,
        events: @escaping @MainActor (MobileSSHAttachEvent) -> Void
    ) async throws -> any MobileSSHAttachedTerminal
}

// MARK: - Channel-backed attachment (plain, tmux)

@MainActor
final class MobileSSHChannelTerminal: MobileSSHAttachedTerminal {
    private let channel: SSHSessionChannel
    private var pump: Task<Void, Never>?

    init(channel: SSHSessionChannel, events: @escaping @MainActor (MobileSSHAttachEvent) -> Void) {
        self.channel = channel
        pump = Task { @MainActor in
            for await event in channel.events {
                switch event {
                case .stdout(let data), .stderr(let data):
                    events(.output(data))
                case .closed:
                    events(.ended)
                case .exitStatus, .exitSignal:
                    break
                }
            }
        }
    }

    func write(_ data: Data) async {
        try? await channel.write(data)
    }

    func resize(columns: Int, rows: Int) async {
        try? await channel.resize(columns: columns, rows: rows)
    }

    func detach() async {
        pump?.cancel()
        await channel.close()
    }
}

// MARK: - Plain

/// Shells opened from this phone. Nothing persists: each workspace is one
/// login shell that ends when its channel closes.
@MainActor
final class MobileSSHPlainProvider: MobileSSHWorkspaceProvider {
    private let connection: SSHConnection
    private var workspaces: [MobileSSHWorkspace] = []
    private var counter = 0

    init(connection: SSHConnection) {
        self.connection = connection
    }

    func listWorkspaces() async throws -> [MobileSSHWorkspace] { workspaces }

    func createWorkspace() async throws -> MobileSSHWorkspace {
        counter += 1
        let id = "shell-\(counter)"
        let name = L10n.string("mobile.ssh.workspace.shellName", defaultValue: "Shell \(counter)")
        let workspace = MobileSSHWorkspace(id: id, name: name, terminals: [MobileSSHTerminal(id: id, name: name)])
        workspaces.append(workspace)
        return workspace
    }

    func closeWorkspace(id: String) async throws {
        workspaces.removeAll { $0.id == id }
    }

    func attach(
        terminalID: String,
        columns: Int,
        rows: Int,
        events: @escaping @MainActor (MobileSSHAttachEvent) -> Void
    ) async throws -> any MobileSSHAttachedTerminal {
        let channel = try await connection.openSession(
            pty: SSHPTYRequest(columns: columns, rows: rows),
            environment: ["LANG": "en_US.UTF-8"],
            start: .shell
        )
        return MobileSSHChannelTerminal(channel: channel) { [weak self] event in
            if case .ended = event { self?.workspaces.removeAll { $0.id == terminalID } }
            events(event)
        }
    }
}

// MARK: - tmux

/// tmux sessions on the server; each session is a workspace. Attaching runs
/// `tmux new-session -A` in a PTY so a missing session is created on demand.
@MainActor
final class MobileSSHTmuxProvider: MobileSSHWorkspaceProvider {
    private let connection: SSHConnection
    /// Absolute path found by ``probe(on:)``; login PATH may omit Homebrew.
    let tmuxPath: String

    init(connection: SSHConnection, tmuxPath: String) {
        self.connection = connection
        self.tmuxPath = tmuxPath
    }

    /// Finds tmux on the server, checking common install locations the
    /// non-interactive PATH can miss.
    static func probe(on connection: SSHConnection) async -> String? {
        let script = #"for p in "$(command -v tmux 2>/dev/null)" /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do [ -n "$p" ] && [ -x "$p" ] && { echo "$p"; exit 0; }; done; exit 1"#
        guard let result = try? await connection.exec("sh -c " + MobileSSHShell.quote(script)),
              result.exitStatus == 0 else { return nil }
        let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    func listWorkspaces() async throws -> [MobileSSHWorkspace] {
        let result = try await connection.exec("\(MobileSSHShell.quote(tmuxPath)) list-sessions -F '#{session_name}' 2>/dev/null")
        guard result.exitStatus == 0 else { return [] } // no server running = no sessions
        return result.stdoutString
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { MobileSSHWorkspace(id: $0, name: $0, terminals: [MobileSSHTerminal(id: $0, name: $0)]) }
    }

    func createWorkspace() async throws -> MobileSSHWorkspace {
        let existing = Set(try await listWorkspaces().map(\.id))
        var index = 1
        while existing.contains("cmux-\(index)") { index += 1 }
        let name = "cmux-\(index)"
        let result = try await connection.exec("\(MobileSSHShell.quote(tmuxPath)) new-session -d -s \(MobileSSHShell.quote(name))")
        guard result.exitStatus == 0 else {
            throw SSHConnectionError.channelRequestRejected("tmux new-session: \(result.stderrString)")
        }
        return MobileSSHWorkspace(id: name, name: name, terminals: [MobileSSHTerminal(id: name, name: name)])
    }

    func closeWorkspace(id: String) async throws {
        _ = try await connection.exec("\(MobileSSHShell.quote(tmuxPath)) kill-session -t \(MobileSSHShell.quote(id))")
    }

    func attach(
        terminalID: String,
        columns: Int,
        rows: Int,
        events: @escaping @MainActor (MobileSSHAttachEvent) -> Void
    ) async throws -> any MobileSSHAttachedTerminal {
        let channel = try await connection.openSession(
            pty: SSHPTYRequest(columns: columns, rows: rows),
            environment: ["LANG": "en_US.UTF-8"],
            start: .exec("\(MobileSSHShell.quote(tmuxPath)) new-session -A -s \(MobileSSHShell.quote(terminalID))")
        )
        return MobileSSHChannelTerminal(channel: channel, events: events)
    }
}

enum MobileSSHShell {
    /// POSIX single-quote escaping.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
