import Foundation

/// Maps a public `term_…` id to the daemon-local numeric surface a byte
/// attachment needs.
///
/// One value per link socket. Every daemon round trip goes through
/// ``CloudTuiCommandRunning`` under a bounded deadline, and every outcome is
/// either an authoritative statement about the terminal or an explicit "try
/// again": a slow daemon or a busy lane is never reported as a missing
/// terminal.
///
/// Resolution order:
/// 1. `resolve-terminal` with the public id. A daemon that maps public ids
///    answers directly, including `surface:null` for a live terminal with no
///    view.
/// 2. If the daemon cannot serve that id (the deployed 897bb7a9 build
///    validates it as a UUIDv4 host id and answers `invalid_terminal_id`, or
///    misses it as a host id for the 1-in-64 ids that happen to have that
///    shape), the authoritative public snapshot decides: absent or exited →
///    exited, no tab → a projection is needed, a tab → the compatibility tree
///    joins that tab to its numeric surface.
/// 3. Anything that never produced an answer is retryable.
struct CloudTerminalAttachmentResolver: Sendable {
    let machineID: String
    let commandRunner: any CloudTuiCommandRunning
    let socketPath: String
    /// Deadline for each daemon round trip. The bundled client's raw bridge
    /// gives up after 10 s; this bound only covers a client that never starts.
    var commandDeadline: Duration
    private let log = CloudTerminalAttachmentLog()

    init(
        machineID: String = "",
        commandRunner: any CloudTuiCommandRunning,
        socketPath: String,
        commandDeadline: Duration = .seconds(15)
    ) {
        self.machineID = machineID
        self.commandRunner = commandRunner
        self.socketPath = socketPath
        self.commandDeadline = commandDeadline
    }

    /// The private resolver's verdict, before any snapshot fallback.
    enum ModernOutcome: Equatable, Sendable {
        case decided(CloudTuiSurfaceIDResolution)
        /// The daemon cannot map this id at all; the public snapshot decides.
        case cannotServeID
    }

    func resolve(terminalID: String) async -> CloudTuiSurfaceIDResolution {
        await resolve(terminalIDs: [terminalID])[terminalID] ?? .retryable("resolver produced no outcome")
    }

    /// Resolves a set of terminal ids with one modern request per id, at most
    /// one snapshot read, and at most one compatibility-tree fetch.
    func resolve(terminalIDs: Set<String>) async -> [String: CloudTuiSurfaceIDResolution] {
        guard !terminalIDs.isEmpty else { return [:] }
        var results: [String: CloudTuiSurfaceIDResolution] = [:]
        var unserved: Set<String> = []
        for terminalID in terminalIDs {
            switch await resolveModern(terminalID: terminalID) {
            case let .decided(outcome):
                results[terminalID] = outcome
            case .cannotServeID:
                unserved.insert(terminalID)
            }
        }
        guard !unserved.isEmpty else { return results }
        let fromSnapshot = await resolveThroughSnapshot(terminalIDs: unserved)
        results.merge(fromSnapshot) { _, new in new }
        return results
    }

    /// Resolves the private command without a compatibility-tree traversal.
    func resolveModern(terminalID: String) async -> ModernOutcome {
        guard let arguments = CloudTuiCommandLine.resolveTerminalArguments(
            socketPath: socketPath,
            terminalID: terminalID
        ) else { return .decided(.retryable("terminal id is not a public term_ id")) }
        do {
            let resolved = try await commandRunner.runTuiCommand(arguments: arguments, deadline: commandDeadline)
            switch CloudTuiLegacySnapshotParser().resolvedSurface(from: resolved) {
            case let .surface(surfaceID):
                return .decided(.resolved(surfaceID))
            case .noPlacement:
                return .decided(.noPlacement)
            case .exited:
                return .decided(.exited)
            case .malformed:
                return .decided(.retryable("malformed resolve-terminal answer"))
            }
        } catch {
            let answer = CloudTuiDaemonAnswer(error: error)
            log.daemonAnswer(machineID: machineID, terminalID: terminalID, command: "resolve-terminal", answer: answer)
            if answer.cannotServeTerminalID { return .cannotServeID }
            return .decided(.retryable(answer.reason))
        }
    }

    /// The authoritative public snapshot carries every terminal with its
    /// lifecycle and views, whether or not the daemon can map its id. A
    /// terminal with a view is joined to its numeric surface through the
    /// compatibility tree, which lists tabs (not terminals) beside `surface`.
    private func resolveThroughSnapshot(terminalIDs: Set<String>) async -> [String: CloudTuiSurfaceIDResolution] {
        let snapshot: [String: Any]
        do {
            let data = try await commandRunner.runTuiCommand(
                arguments: CloudTuiCommandLine.snapshotArguments(socketPath: socketPath),
                deadline: commandDeadline
            )
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  CmuxTuiSnapshotParser.authoritativeGraphIsValid(object) else {
                return Self.uniform(terminalIDs, .retryable("session snapshot was not an authoritative graph"))
            }
            snapshot = object
        } catch {
            let answer = CloudTuiDaemonAnswer(error: error)
            for terminalID in terminalIDs {
                log.daemonAnswer(machineID: machineID, terminalID: terminalID, command: "session current snapshot", answer: answer)
            }
            return Self.uniform(terminalIDs, .retryable("snapshot: \(answer.reason)"))
        }
        var results: [String: CloudTuiSurfaceIDResolution] = [:]
        var placedTabs: [String: String] = [:]
        for terminalID in terminalIDs {
            switch Self.placement(in: snapshot, terminalID: terminalID) {
            case .absent, .exited:
                results[terminalID] = .exited
            case .detached:
                results[terminalID] = .noPlacement
            case let .notReady(lifecycle):
                results[terminalID] = .retryable("terminal is \(lifecycle)")
            case let .placed(tabID):
                placedTabs[terminalID] = tabID
            }
        }
        guard !placedTabs.isEmpty else { return results }
        do {
            let tree = try await commandRunner.runTuiCommand(
                arguments: CloudTuiCommandLine.legacyListWorkspacesArguments(socketPath: socketPath),
                deadline: commandDeadline
            )
            let joined = CloudTuiLegacySnapshotParser().surfaceIDs(from: tree, terminalIDs: Set(placedTabs.keys))
            for (terminalID, tabID) in placedTabs {
                results[terminalID] = joined[terminalID].map(CloudTuiSurfaceIDResolution.resolved)
                    ?? .retryable("tab \(tabID) is in the snapshot but not yet in the compatibility tree")
            }
        } catch {
            let answer = CloudTuiDaemonAnswer(error: error)
            for terminalID in placedTabs.keys {
                log.daemonAnswer(machineID: machineID, terminalID: terminalID, command: "list-workspaces", answer: answer)
                results[terminalID] = .retryable("compatibility tree: \(answer.reason)")
            }
        }
        return results
    }

    private enum SnapshotPlacement: Equatable {
        case absent
        case exited
        case detached
        case notReady(String)
        case placed(tabID: String)
    }

    /// Where the authoritative graph puts one terminal. Several views of one
    /// terminal are legal; any of them is attachable, so the first is used.
    private static func placement(in snapshot: [String: Any], terminalID: String) -> SnapshotPlacement {
        let terminals = snapshot["terminals"] as? [[String: Any]] ?? []
        guard let terminal = terminals.first(where: { $0["id"] as? String == terminalID }) else { return .absent }
        let lifecycle = (terminal["lifecycle"] as? String) ?? "running"
        switch lifecycle {
        case "exited", "tombstoned":
            return .exited
        case "running":
            break
        default:
            return .notReady(lifecycle)
        }
        let tabs = (snapshot["tabs"] as? [[String: Any]] ?? []).filter {
            $0["content_kind"] as? String == "terminal" && $0["content_id"] as? String == terminalID
        }
        if let tabID = tabs.first?["id"] as? String, !tabID.isEmpty {
            return .placed(tabID: tabID)
        }
        return .detached
    }

    private static func uniform(_ terminalIDs: Set<String>, _ outcome: CloudTuiSurfaceIDResolution) -> [String: CloudTuiSurfaceIDResolution] {
        Dictionary(uniqueKeysWithValues: terminalIDs.map { ($0, outcome) })
    }
}
