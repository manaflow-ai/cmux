import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
import Darwin
import Foundation

/// Agent chats between builds (`chat` records): the chat moves from the source build's acpmux to
/// this one's with its history, queue and draft (`acpmux transfer`, cmux-tui/crates/acpmux
/// `hub/transfer_out.rs`), then opens here as a conversation tab. Builds that share one acpmux
/// (Release and NIGHTLY share `~/.acpmux`) move only the tab.
extension SessionTransferService {
    /// How long a pull waits for `acpmux transfer`. A move still running then is left to finish
    /// (or give the chat back) on its own: ended midway, the source chat would stay frozen.
    static let chatMoveLimit: Duration = .seconds(240)

    /// This build's chats another build can take, by tab id: chats of this Mac's acpmux (not the
    /// Chief home's, not another machine's) that have a session.
    func localChats() -> [String: (session: String, harness: String?)] {
        guard let tabs = services?.agentTabs, let localHost = tabs.localHost else { return [:] }
        var chats: [String: (session: String, harness: String?)] = [:]
        for (key, record) in tabs.listTabs() where record.host == localHost {
            if let session = tabs.session(of: key) { chats[key] = (session, record.harness) }
        }
        return chats
    }

    /// This build's acpmux (its socket and home), nil without one.
    func acpmuxEnvironment() -> AcpmuxEnvironment? {
        services.flatMap(QuitAgents.environment)
    }

    /// Moves chat `item` from `peer` and opens it here; the source tab closes once the chat is
    /// here, even when its tab could not open (the source copy is closed by then).
    func moveChat(_ item: SessionTransferItem, from peer: SessionTransferPeer, interrupt: Bool, cwd: String? = nil) async throws {
        guard let services else { throw Failure.unavailable }
        // Nothing moves unless its tab can open here.
        guard services.agentTabs.canHost(on: services.daemon) else { throw Failure.agentNotOpened }
        let session = try await takeChat(item, interrupt: interrupt, cwd: cwd)
        do {
            _ = try await openChat(session, title: item.title)
        } catch {
            try? await completeOnPeer(item: item, peer: peer)
            throw Failure.chatInChats
        }
        try await completeOnPeer(item: item, peer: peer)
    }

    /// Brings chat `item` into this build's acpmux and returns its session here. Its running turn
    /// stops when `interrupt`, else the move is refused. It works in `cwd` here when given. A failed
    /// move leaves it in the source.
    private func takeChat(_ item: SessionTransferItem, interrupt: Bool, cwd: String?) async throws -> String {
        guard let session = item.agentSessionID, let socket = item.acpmuxSocket else { throw Failure.missingAgentID }
        guard let services, let own = acpmuxEnvironment() else { throw Failure.unavailable }
        if Self.sameFile(socket, own.socketPath) { return session }
        try await (services.agentTabs.localSessionHost ?? services.agentTabs.host).prewarm()
        // An earlier pull moved it here already (its tab did not open, or the source did not close).
        if await Self.hasOpenChat(session, in: own) { return session }
        // `/tmp` is shared and the source's daemon hands this one the chat's files; a socket no
        // daemon answers would make `acpmux transfer` start this build's acpmux in its home.
        guard Self.isOwnedSocket(socket) else { throw Failure.peerRefused }
        guard Self.answers(socket) else { throw Failure.sourceAgentsStopped }
        var environment = ProcessInfo.processInfo.environment
        environment["ACPMUX_SOCKET"] = socket
        if let home = item.acpmuxHome { environment["ACPMUX_HOME"] = home }
        let arguments = ["--json", "transfer", session, "--to", own.socketPath] + (interrupt ? ["--interrupt"] : [])
            + (cwd.map { ["--cwd", $0] } ?? [])
        // A pull past its deadline starts no move nobody waits for.
        try Task.checkCancellation()
        guard let result = try await Self.runToEnd(own.executable, arguments, environment: environment, limit: Self.chatMoveLimit) else {
            throw Failure.chatInChats
        }
        guard result.status == 0 else { throw Self.acpmuxFailure(result.stderr, status: result.status) }
        let moved = try? JSONSerialization.blockingJSONObject(with: result.stdout) as? [String: Any]
        return moved?["sessionId"] as? String ?? session
    }

    /// Shows `session` of this build's acpmux in a new workspace of the active window (the tab
    /// already showing it instead, when there is one) and returns the workspace id.
    func openChat(_ session: String, title: String) async throws -> String {
        guard let services else { throw Failure.unavailable }
        let store = services.daemon.store
        if let key = services.agentTabs.tab(showing: session), let tab = store.tab(id: key),
           let pane = store.pane(containing: tab.surface), let workspace = store.workspace(containing: pane.handle)?.key {
            return workspace.rawValue
        }
        let target = services.windows.targetWindow(preferring: services.windows.active?.state.id)
        var spawn = WorkspaceSpawn(name: title.isEmpty ? nil : title)
        spawn.firstSession = session
        let id = try await services.windows.createWorkspace(spawn, into: target)
        guard try await hasConversationTab(id) else { throw Failure.agentNotOpened }
        return id
    }

    /// Whether `environment`'s acpmux has chat `session`, not closed.
    private nonisolated static func hasOpenChat(_ session: String, in environment: AcpmuxEnvironment) async -> Bool {
        var variables = ProcessInfo.processInfo.environment
        variables.merge(environment.childEnvironment) { $1 }
        guard let result = try? await ProcessRunner.run(executable: environment.executable, arguments: ["--json", "info", session],
                                                        environment: variables, timeout: .seconds(10), clock: ContinuousClock()),
              result.status == 0,
              let info = try? JSONSerialization.blockingJSONObject(with: result.stdout) as? [String: Any] else { return false }
        return info["status"] as? String != "closed"
    }

    /// The failed move as acpmux's `--json` error line (the last line of `stderr`) tells it: a
    /// refusal the app words itself by its `detail`, else acpmux's message, else the text.
    private nonisolated static func acpmuxFailure(_ stderr: Data, status: Int32) -> Failure {
        let text = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let last = text.split(separator: "\n").last.map(String.init) ?? ""
        let line = try? JSONSerialization.blockingJSONObject(with: Data(last.utf8)) as? [String: Any]
        let error = line?["error"] as? [String: Any]
        if error?["detail"] as? String == "cwd_missing", let folder = (error?["data"] as? [String: Any])?["cwd"] as? String {
            return .chatFolderMissing(folder)
        }
        if let message = error?["message"] as? String ?? line?["error"] as? String { return .chatNotMoved(message) }
        return .chatNotMoved(text.isEmpty ? "acpmux exited with \(status)" : text)
    }

    /// Whether two paths name one file (a socket reached as `/tmp/…` and `/private/tmp/…`).
    private nonisolated static func sameFile(_ a: String, _ b: String) -> Bool {
        var first = stat(), second = stat()
        // SAFETY: each stat reads the NUL-terminated copy of its path made for the call and writes one struct
        // stat into a local live for the call.
        guard unsafe blockingStat(a, &first) == 0, unsafe blockingStat(b, &second) == 0 else { return a == b }
        return first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    /// Whether a daemon accepts connections on unix socket `path`.
    private nonisolated static func answers(_ path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var noSigPipe: Int32 = 1 // it only connects, but no write on it may ever signal
        // SAFETY: setsockopt reads the Int32 it is given the size of, a local live for the call.
        _ = unsafe setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        guard let address = UnixSocketAddress(path: path) else { return false }
        return address.connect(descriptor) == 0
    }

    /// Runs `executable` and returns its exit status and output, or nil when it is still running
    /// after `limit` or the caller is cancelled; it is never ended early (ended midway, the source
    /// chat would stay frozen). The spawn runs off the caller's actor; the output drains while it
    /// runs, and a daemon it starts cannot hold the result open. The person waits for the move, so
    /// it runs at userBlocking. Throws when it could not start.
    nonisolated static func runToEnd(_ executable: URL, _ arguments: [String], environment: [String: String], limit: Duration,
                                     processes: any ProcessRunning = AsyncProcess(),
                                     clock: any Clock<Duration> = ContinuousClock()) async throws -> (status: Int32, stdout: Data, stderr: Data)? {
        try Task.checkCancellation()
        let request = ProcessRequest(executable, arguments, environment: environment, errorOutput: .separate,
                                     onCancel: .finish, priority: .userBlocking)
        do {
            guard let outcome = try await processes.outcome(of: request, waitingAtMost: limit, owner: "SessionTransfer.runToEnd",
                                                            clock: clock) else { return nil }
            return (outcome.status, outcome.output, outcome.errorOutput)
        } catch {
            throw Failure.chatNotMoved(String(describing: error))
        }
    }
}
