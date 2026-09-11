import Foundation

/// Maps a public `term_…` id to the daemon-local numeric surface a byte
/// attachment needs.
///
/// One value per link socket. Every daemon round trip goes through
/// ``CloudTuiCommandRunning`` under a bounded deadline, so the mapping is
/// testable against scripted daemon answers and never depends on a machine.
struct CloudTerminalAttachmentResolver: Sendable {
    let commandRunner: any CloudTuiCommandRunning
    let socketPath: String
    /// Deadline for each daemon round trip.
    var commandDeadline: Duration = .seconds(30)

    init(
        commandRunner: any CloudTuiCommandRunning,
        socketPath: String,
        commandDeadline: Duration = .seconds(30)
    ) {
        self.commandRunner = commandRunner
        self.socketPath = socketPath
        self.commandDeadline = commandDeadline
    }

    /// Resolves one terminal, using the legacy tree only when the daemon
    /// explicitly reports that the private resolver cannot serve the id. Other
    /// failures fail closed to prevent stale-id routing.
    func resolve(terminalID: String) async -> CloudTuiSurfaceIDResolution {
        let modern = await resolveModern(terminalID: terminalID)
        guard modern == .unsupported else { return modern }
        guard let surfaceID = await resolveLegacy(terminalIDs: [terminalID])[terminalID] else {
            return .failed
        }
        return .resolved(surfaceID)
    }

    /// Resolves a set of terminal ids with one modern request per id and at
    /// most one legacy tree fallback. The compatibility parser performs one
    /// O(N) traversal for all unresolved ids.
    func resolve(terminalIDs: Set<String>) async -> [String: CloudTuiSurfaceIDResolution] {
        guard !terminalIDs.isEmpty else { return [:] }
        var results: [String: CloudTuiSurfaceIDResolution] = [:]
        var legacyIDs: Set<String> = []
        for terminalID in terminalIDs {
            let result = await resolveModern(terminalID: terminalID)
            results[terminalID] = result
            if result == .unsupported {
                legacyIDs.insert(terminalID)
            }
        }
        if !legacyIDs.isEmpty {
            let legacy = await resolveLegacy(terminalIDs: legacyIDs)
            for terminalID in legacyIDs {
                results[terminalID] = legacy[terminalID].map(CloudTuiSurfaceIDResolution.resolved) ?? .failed
            }
        }
        return results
    }

    /// Resolves the private command without a compatibility-tree traversal.
    func resolveModern(terminalID: String) async -> CloudTuiSurfaceIDResolution {
        guard let arguments = CloudTuiCommandLine.resolveTerminalArguments(
            socketPath: socketPath,
            terminalID: terminalID
        ) else { return .failed }
        let parser = CloudTuiLegacySnapshotParser()
        do {
            let resolved = try await commandRunner.runTuiCommand(arguments: arguments, deadline: commandDeadline)
            switch parser.resolvedSurface(from: resolved) {
            case let .surface(surfaceID):
                return .resolved(surfaceID)
            case .noPlacement:
                return .noPlacement
            case .exited:
                return .exited
            case .malformed:
                return .failed
            }
        } catch {
            if Self.isExplicitUnsupportedResolverError(error) {
                return .unsupported
            }
            // A pre-protocol-9 daemon has no generation-aware resolver. Probe
            // the authoritative identify response before allowing the legacy
            // tree fallback; all other failures remain fail-closed.
            guard let identifyArguments = CloudTuiCommandLine.identifyArguments(socketPath: socketPath),
                  let identify = try? await commandRunner.runTuiCommand(arguments: identifyArguments, deadline: commandDeadline),
                  let protocolVersion = parser.protocolVersion(from: identify) else {
                return .failed
            }
            return protocolVersion < 9 ? .unsupported : .failed
        }
    }

    /// One compatibility-tree fetch joined for every requested id.
    func resolveLegacy(terminalIDs: Set<String>) async -> [String: UInt64] {
        guard !terminalIDs.isEmpty,
              let tree = try? await commandRunner.runTuiCommand(
                  arguments: CloudTuiCommandLine.legacyListWorkspacesArguments(socketPath: socketPath),
                  deadline: commandDeadline
              ) else { return [:] }
        return CloudTuiLegacySnapshotParser().surfaceIDs(from: tree, terminalIDs: terminalIDs)
    }

    /// Whether the daemon's answer means "this resolver cannot serve me",
    /// which sends the caller to the compatibility tree instead of failing
    /// closed.
    ///
    /// Two answers qualify. `operation.unsupported` is a daemon that predates
    /// the resolver. `invalid_terminal_id` is an id-space mismatch:
    /// `resolve-terminal` takes a *terminal host* id (UUIDv4 hex, per
    /// spec/sdk-schema.json), while everything the app holds is a public
    /// `term_…` resource id whose hex is not a UUIDv4 and which no command maps
    /// to a host id. So the modern resolver can never answer for the ids this
    /// app has, and treating that as a hard failure made every cloud terminal
    /// fail with "cmux-tui did not report the new terminal". The compatibility
    /// tree does carry the mapping (`terminal_resource_id` beside `surface`),
    /// so the fallback is the path that actually resolves.
    static func isExplicitUnsupportedResolverError(_ error: Error) -> Bool {
        guard case let CloudMachineLink.LinkError.exited(_, output) = error else { return false }
        let lines = output.split(whereSeparator: \.isNewline)
        for line in lines {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if object["code"] as? String == "operation.unsupported"
                || object["error_code"] as? String == "operation.unsupported" {
                return true
            }
            let detailError = (object["details"] as? [String: Any])?["error"] as? String
            if object["message"] as? String == "invalid_terminal_id"
                || detailError == "invalid_terminal_id" {
                return true
            }
        }
        return false
    }
}
