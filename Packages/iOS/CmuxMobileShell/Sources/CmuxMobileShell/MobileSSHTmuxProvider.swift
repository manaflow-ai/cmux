internal import CmuxMobileSSH
internal import CmuxMobileSupport
import Foundation

/// tmux over control mode (PRD D9, D22): each tmux session is a workspace,
/// each PANE is one terminal tab (ordered by window, then pane), and
/// "New Terminal" opens a tmux window in the session.
///
/// Terminal ids are `<session>/%<pane>`; pane ids are stable for the pane's
/// life and unique on the server. Listing, creating, and closing use one-off
/// exec commands; attached panes stream through one ``MobileSSHTmuxControlClient``
/// per session, created on first attach and closed with the last pane.
@MainActor
final class MobileSSHTmuxProvider: MobileSSHWorkspaceProvider, MobileSSHTerminalCreating, MobileSSHTopologyReporting,
    MobileSSHCurrentDirectoryProviding {
    private let connection: SSHConnection
    /// Absolute path found by ``probe(on:)``; login PATH may omit Homebrew.
    let tmuxPath: String
    /// A private tmux server (`tmux -L <name>`); `nil` is the user's default
    /// server, which the app always uses. Lab tests use their own server.
    let socketName: String?
    private var controls: [String: MobileSSHTmuxControlClient] = [:]
    private var opening: [String: Task<MobileSSHTmuxControlClient, any Error>] = [:]
    /// The one stale-grouped-session collection per connection, run before
    /// the first listing or attach.
    private var collection: Task<Void, Never>?
    var onTopologyChange: (@MainActor () -> Void)?

    init(connection: SSHConnection, tmuxPath: String, socketName: String? = nil) {
        self.connection = connection
        self.tmuxPath = tmuxPath
        self.socketName = socketName
    }

    /// Finds tmux on the server, checking common install locations the
    /// non-interactive PATH can miss.
    static func probe(on connection: SSHConnection) async -> String? {
        let script = #"for p in "$(command -v tmux 2>/dev/null)" /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do [ -n "$p" ] && [ -x "$p" ] && { echo "$p"; exit 0; }; done; exit 1"#
        guard let result = try? await connection.exec("sh -c " + script.posixShellSingleQuoted),
              result.exitStatus == 0 else { return nil }
        let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// The shell-quoted tmux command, with the server socket when private.
    var tmux: String {
        let path = tmuxPath.posixShellSingleQuoted
        guard let socketName else { return path }
        return path + " -L " + socketName.posixShellSingleQuoted
    }

    // MARK: Grouped sessions

    /// Kills the phone's grouped sessions that no client is attached to.
    ///
    /// A grouped session outlives its control client when the SSH channel
    /// drops without a graceful ``MobileSSHTmuxControlClient/close()`` (app
    /// killed, network lost), because tmux is deliberately not asked to
    /// destroy it (see ``MobileSSHTmuxControlClient``). Every phone creates
    /// its grouped session already attached, so an unattached one is never
    /// in use. Runs once per connection, before the first listing or attach.
    func collectStaleGroupedSessions() async {
        if let collection { return await collection.value }
        let task = Task { @MainActor [connection, tmux] in
            let format = "#{session_attached}:#{session_name}".posixShellSingleQuoted
            guard let result = try? await connection.exec("\(tmux) list-sessions -F \(format) 2>/dev/null"),
                  result.exitStatus == 0 else { return } // no server running
            let stale = Self.staleGroupedSessions(result.stdoutString)
            guard !stale.isEmpty else { return }
            // One tmux invocation: `kill-session` detaches any client before
            // freeing the session, so a client that attached meanwhile is
            // sent `%exit`, never left on a freed session.
            let kills = stale.map { "kill-session -t " + ("=" + $0).posixShellSingleQuoted }
            _ = try? await connection.exec("\(tmux) " + kills.joined(separator: " \\; ") + " 2>/dev/null")
        }
        collection = task
        await task.value
    }

    /// Names of the phone's grouped sessions with no attached client, from
    /// `list-sessions -F '#{session_attached}:#{session_name}'`. Session
    /// names cannot contain `:`, so the first `:` splits the fields.
    nonisolated static func staleGroupedSessions(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let colon = line.firstIndex(of: ":"), line[..<colon] == "0" else { return nil }
            let name = String(line[line.index(after: colon)...])
            return name.contains(MobileSSHTmuxControlClient.groupedSessionMarker) ? name : nil
        }
    }

    // MARK: Ids

    nonisolated static func terminalID(session: String, pane: Int) -> String {
        "\(session)/%\(pane)"
    }

    /// Splits `<session>/%<pane>`. Session names may contain `/`, so split at the last `/%`.
    nonisolated static func parseTerminalID(_ id: String) -> (session: String, pane: Int)? {
        guard let range = id.range(of: "/%", options: .backwards),
              let pane = Int(id[range.upperBound...]) else { return nil }
        return (String(id[..<range.lowerBound]), pane)
    }

    // MARK: Workspaces

    /// One row of `list-panes -a`.
    struct PaneRow: Equatable {
        var session: String
        var windowIndex: Int
        var windowName: String
        var windowPaneCount: Int
        var pane: Int
        var paneIndex: Int
    }

    /// `:`-separated: tmux forbids `:` in session names and prints control
    /// characters (a tab) as `_`. The window name is last, so it may contain `:`.
    nonisolated static let listFormat = ["#{session_name}", "#{window_index}", "#{window_panes}", "#{pane_id}", "#{pane_index}", "#{window_name}"]
        .joined(separator: ":")

    nonisolated static func parsePaneRows(_ output: String) -> [PaneRow] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6, let windowIndex = Int(fields[1]), let count = Int(fields[2]),
                  let pane = MobileSSHTmuxControlParser.id(fields[3], "%"), let paneIndex = Int(fields[4]) else { return nil }
            return PaneRow(session: fields[0], windowIndex: windowIndex, windowName: fields[5], windowPaneCount: count, pane: pane, paneIndex: paneIndex)
        }
    }

    /// Groups pane rows into workspaces, hiding the phone's grouped sessions.
    /// Tabs are ordered by window, then pane. Each window is a tab-switcher
    /// section; a pane's full name (`<index>:<window> · pane <n>` in a split
    /// window) stays its terminal title, the section row shows the short form.
    nonisolated static func workspaces(from rows: [PaneRow]) -> [MobileSSHWorkspace] {
        var order: [String] = []
        var bySession: [String: [PaneRow]] = [:]
        for row in rows where !row.session.contains(MobileSSHTmuxControlClient.groupedSessionMarker) {
            if bySession[row.session] == nil { order.append(row.session) }
            bySession[row.session, default: []].append(row)
        }
        return order.map { session in
            let panes = (bySession[session] ?? []).sorted { ($0.windowIndex, $0.paneIndex) < ($1.windowIndex, $1.paneIndex) }
            var sections: [MobileSSHWorkspaceSection] = []
            for row in panes where sections.last?.id != String(row.windowIndex) {
                sections.append(MobileSSHWorkspaceSection(id: String(row.windowIndex), title: "\(row.windowIndex): \(row.windowName)"))
            }
            return MobileSSHWorkspace(
                id: session,
                name: session,
                terminals: panes.map { row in
                    let window = "\(row.windowIndex):\(row.windowName)"
                    let position = (panes.filter { $0.windowIndex == row.windowIndex }.firstIndex(of: row) ?? 0) + 1
                    let split = row.windowPaneCount > 1
                    let name = split
                        ? L10n.string("mobile.ssh.tmux.paneName", defaultValue: "\(window) · pane \(position)")
                        : window
                    let paneLabel = L10n.string("mobile.ssh.tabs.paneLabel", defaultValue: "Pane \(position)")
                    return MobileSSHTerminal(
                        id: terminalID(session: session, pane: row.pane),
                        name: name,
                        placement: MobileSSHTerminalPlacement(
                            sectionID: String(row.windowIndex),
                            paneID: "%\(row.pane)",
                            title: split ? paneLabel : row.windowName,
                            paneLabel: nil
                        )
                    )
                },
                kind: .tmux,
                sections: sections
            )
        }
    }

    func listWorkspaces() async throws -> [MobileSSHWorkspace] {
        await collectStaleGroupedSessions()
        let result = try await connection.exec("\(tmux) list-panes -a -F \(Self.listFormat.posixShellSingleQuoted) 2>/dev/null")
        guard result.exitStatus == 0 else { return [] } // no server running = no sessions
        return Self.workspaces(from: Self.parsePaneRows(result.stdoutString))
    }

    func createWorkspace() async throws -> MobileSSHWorkspace {
        let existing = Set(try await listWorkspaces().map(\.id))
        var index = 1
        while existing.contains("cmux-\(index)") { index += 1 }
        let name = "cmux-\(index)"
        try await runStartingShell("new-session", "-s \(name.posixShellSingleQuoted)")
        return try await listWorkspaces().first { $0.id == name }
            ?? MobileSSHWorkspace(id: name, name: name, terminals: [], kind: .tmux)
    }

    func closeWorkspace(id: String) async throws {
        if let control = controls.removeValue(forKey: id) { await control.close() }
        _ = try await connection.exec("\(tmux) kill-session -t \(("=" + id).posixShellSingleQuoted)")
    }

    /// Opens a tmux window (without switching the session's current window,
    /// so a laptop looking at the session stays where it is).
    func createTerminal(inWorkspace workspaceID: String) async throws -> MobileSSHTerminal {
        let output = try await runStartingShell("new-window", "-t \(("=" + workspaceID + ":").posixShellSingleQuoted) -P -F '#{pane_id}'")
        guard let pane = MobileSSHTmuxControlParser.id(output.trimmingCharacters(in: .whitespacesAndNewlines), "%") else {
            throw SSHConnectionError.channelRequestRejected("tmux new-window: \(output)")
        }
        let id = Self.terminalID(session: workspaceID, pane: pane)
        let listed = try await listWorkspaces().first { $0.id == workspaceID }?.terminals.first { $0.id == id }
        return listed ?? MobileSSHTerminal(id: id, name: id)
    }

    /// "Split Pane" on a window section: splits the window's active pane
    /// (detached, so no client's current pane moves) and returns the new
    /// pane's terminal.
    func splitWindow(inWorkspace workspaceID: String, window: String) async throws -> MobileSSHTerminal {
        let target = ("=" + workspaceID + ":" + window).posixShellSingleQuoted
        let output = try await runStartingShell("split-window", "-t \(target) -P -F '#{pane_id}'")
        guard let pane = MobileSSHTmuxControlParser.id(output.trimmingCharacters(in: .whitespacesAndNewlines), "%") else {
            throw SSHConnectionError.channelRequestRejected("tmux split-window: \(output)")
        }
        let id = Self.terminalID(session: workspaceID, pane: pane)
        let listed = try await listWorkspaces().first { $0.id == workspaceID }?.terminals.first { $0.id == id }
        return listed ?? MobileSSHTerminal(id: id, name: id)
    }

    /// The pane's working directory (`#{pane_current_path}`).
    func currentDirectory(terminalID: String) async -> String? {
        guard let (_, pane) = Self.parseTerminalID(terminalID),
              let result = try? await connection.exec("\(tmux) display-message -p -t %\(pane) '#{pane_current_path}'"),
              result.exitStatus == 0 else { return nil }
        let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Runs a detached (`-d`) tmux command that starts a shell, passing
    /// `COLORTERM=truecolor` (`-e`, tmux 3.2+) and retrying without it on
    /// older tmux.
    @discardableResult
    private func runStartingShell(_ verb: String, _ arguments: String) async throws -> String {
        let withEnv = try await connection.exec("\(tmux) \(verb) -d -e COLORTERM=truecolor \(arguments)")
        if withEnv.exitStatus == 0 { return withEnv.stdoutString }
        let result = try await connection.exec("\(tmux) \(verb) -d \(arguments)")
        guard result.exitStatus == 0 else {
            throw SSHConnectionError.channelRequestRejected("tmux \(verb): \(result.stderrString)")
        }
        return result.stdoutString
    }

    // MARK: Attach

    func attach(
        terminalID: String,
        columns: Int,
        rows: Int,
        events: @escaping @MainActor (MobileSSHAttachEvent) -> Void
    ) async throws -> any MobileSSHAttachedTerminal {
        guard let (session, pane) = Self.parseTerminalID(terminalID) else {
            throw SSHConnectionError.channelRequestRejected("tmux: not a pane id: \(terminalID)")
        }
        let control = try await control(session: session)
        // Size before seeding so the capture reflects the phone-sized window.
        control.setClientSize(columns: columns, rows: rows)
        control.attach(pane: pane, events: events)
        return MobileSSHTmuxPaneTerminal(pane: pane, control: control) { [weak self] in
            await self?.paneDetached(session: session, control: control)
        } resize: { columns, rows in
            control.setClientSize(columns: columns, rows: rows)
        }
    }

    private func control(session: String) async throws -> MobileSSHTmuxControlClient {
        if let control = controls[session], !control.isClosed { return control }
        if let task = opening[session] { return try await task.value }
        let task = Task { @MainActor in
            await self.collectStaleGroupedSessions()
            return try await MobileSSHTmuxControlClient.open(connection: self.connection, tmux: self.tmux, session: session)
        }
        opening[session] = task
        defer { opening[session] = nil }
        let control = try await task.value
        control.onTopologyChange = { [weak self] in self?.onTopologyChange?() }
        control.onClose = { [weak self, weak control] in
            guard let self, let control, self.controls[session] === control else { return }
            self.controls[session] = nil
        }
        controls[session] = control
        return control
    }

    /// The last pane of a session detached: close its control client and
    /// grouped session before returning, so a disconnect that follows
    /// cannot cut the kill off.
    private func paneDetached(session: String, control: MobileSSHTmuxControlClient) async {
        guard control.attachedPaneCount == 0, controls[session] === control else { return }
        controls[session] = nil
        await control.close()
    }

    /// Test hook: the grouped session name serving `session`, if attached.
    func groupedSessionName(for session: String) -> String? {
        controls[session]?.groupedSessionName
    }
}

/// One attached tmux pane. Input goes through `send-keys -H`; the phone's
/// grid sizes the control client, not the pane (its size comes from the
/// window layout and reaches the surface as `.remoteGrid`).
@MainActor
final class MobileSSHTmuxPaneTerminal: MobileSSHAttachedTerminal {
    private let pane: Int
    private let control: MobileSSHTmuxControlClient
    private let onDetach: @MainActor () async -> Void
    private let onResize: @MainActor (Int, Int) -> Void

    init(
        pane: Int,
        control: MobileSSHTmuxControlClient,
        detach: @escaping @MainActor () async -> Void,
        resize: @escaping @MainActor (Int, Int) -> Void
    ) {
        self.pane = pane
        self.control = control
        onDetach = detach
        onResize = resize
    }

    func write(_ data: Data) async {
        control.write(data, pane: pane)
    }

    func resize(columns: Int, rows: Int) async {
        onResize(columns, rows)
    }

    func detach() async {
        control.detach(pane: pane)
        await onDetach()
    }
}

/// Providers whose workspaces can gain terminal tabs from the phone
/// ("New Terminal"): tmux opens a window, cmux-tui a terminal.
@MainActor
protocol MobileSSHTerminalCreating: AnyObject {
    func createTerminal(inWorkspace workspaceID: String) async throws -> MobileSSHTerminal
}

/// Providers that learn about remote topology changes (windows, panes)
/// while attached, so the runtime can refresh the workspace rows.
@MainActor
protocol MobileSSHTopologyReporting: AnyObject {
    var onTopologyChange: (@MainActor () -> Void)? { get set }
}
