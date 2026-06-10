import Foundation
import Network

/// Quick reachability probe for the SSH endpoint behind a remote workspace.
///
/// The auto-reconnect loop uses this to distinguish "the host is temporarily
/// failing" (keep retrying with backoff) from "the host cannot be reached at
/// all" (suspend the loop and wait for a manual reconnect, see
/// https://github.com/manaflow-ai/cmux/issues/5734).
///
/// The probe resolves the effective endpoint with `ssh -G` so ~/.ssh/config
/// aliases, `HostName` overrides, and `ProxyJump` hops are honored. Transports
/// that cannot be probed with a direct TCP connection (`ProxyCommand`) report
/// `.indeterminate`, which the policy treats like a reachable host so the
/// loop never suspends on a guess.
enum WorkspaceRemoteHostReachabilityProbe {
    struct Endpoint: Equatable {
        let host: String
        let port: Int
    }

    static let defaultTimeout: TimeInterval = 2.5
    private static let sshResolveTimeout: TimeInterval = 3.0
    private static let probeQueue = DispatchQueue(
        label: "com.cmux.remote-host-reachability",
        qos: .utility
    )

    /// Probe the SSH endpoint for `destination`. The completion runs on an
    /// arbitrary queue; callers hop back to their own queue.
    static func probe(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        timeout: TimeInterval = defaultTimeout,
        completion: @escaping (WorkspaceRemoteHostProbeOutcome) -> Void
    ) {
        // Endpoint resolution shells out to `ssh -G` and can block for up to
        // its timeout; run it on the concurrent utility pool so simultaneous
        // probes from multiple workspaces don't serialize behind it (the
        // serial probeQueue is reserved for NWConnection callbacks).
        DispatchQueue.global(qos: .utility).async {
            guard let endpoint = resolveEndpoint(
                destination: destination,
                port: port,
                identityFile: identityFile,
                sshOptions: sshOptions
            ) else {
                completion(.indeterminate)
                return
            }
            probeTCP(
                host: endpoint.host,
                port: endpoint.port,
                timeout: timeout,
                completion: completion
            )
        }
    }

    /// Resolve the effective `(host, port)` for an SSH destination using
    /// `ssh -G`. Returns nil when the endpoint cannot be probed directly
    /// (ProxyCommand transports, unparsable output, or resolution failure).
    ///
    /// `sshConfigFile` is a test seam: passing a path (such as `/dev/null`)
    /// pins resolution to that config via `ssh -F`, keeping tests hermetic
    /// against the ambient `~/.ssh/config`. Production callers leave it nil
    /// so the user's real config (aliases, HostName, ProxyJump) is honored.
    static func resolveEndpoint(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        sshConfigFile: String? = nil
    ) -> Endpoint? {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty, !trimmedDestination.hasPrefix("-") else { return nil }

        var arguments = ["-G"]
        if let sshConfigFile, !sshConfigFile.isEmpty {
            arguments += ["-F", sshConfigFile]
        }
        if let port, port > 0 {
            arguments += ["-p", String(port)]
        }
        if let identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["-i", identityFile]
        }
        for option in sshOptions {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            arguments += ["-o", trimmed]
        }
        arguments.append(trimmedDestination)

        guard let output = runSSHConfigResolution(arguments: arguments) else { return nil }
        let resolved = parseSSHConfigOutput(output)

        if let proxyJump = resolved.proxyJump {
            // Reachability of the first hop is the right signal for "can this
            // network reach the SSH entry point at all".
            guard let jump = parseJumpSpec(proxyJump) else { return nil }
            var jumpArguments = ["-G"]
            if let sshConfigFile, !sshConfigFile.isEmpty {
                jumpArguments += ["-F", sshConfigFile]
            }
            jumpArguments.append(jump.destination)
            guard let jumpOutput = runSSHConfigResolution(arguments: jumpArguments) else {
                return nil
            }
            let jumpResolved = parseSSHConfigOutput(jumpOutput)
            guard jumpResolved.proxyCommand == nil, jumpResolved.proxyJump == nil else { return nil }
            guard let host = jumpResolved.hostName ?? jump.host else { return nil }
            let jumpPort = jump.port ?? jumpResolved.port ?? 22
            return Endpoint(host: host, port: jumpPort)
        }

        guard resolved.proxyCommand == nil else { return nil }
        guard let host = resolved.hostName else { return nil }
        return Endpoint(host: host, port: resolved.port ?? port ?? 22)
    }

    struct ResolvedSSHConfig: Equatable {
        var hostName: String?
        var port: Int?
        var proxyJump: String?
        var proxyCommand: String?
    }

    /// Parse the key/value lines printed by `ssh -G`.
    static func parseSSHConfigOutput(_ output: String) -> ResolvedSSHConfig {
        var resolved = ResolvedSSHConfig()
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let spaceIndex = trimmed.firstIndex(of: " ") else { continue }
            let key = trimmed[..<spaceIndex].lowercased()
            let value = String(trimmed[trimmed.index(after: spaceIndex)...])
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value.lowercased() != "none" else { continue }
            switch key {
            case "hostname":
                resolved.hostName = value
            case "port":
                resolved.port = Int(value)
            case "proxyjump":
                resolved.proxyJump = value
            case "proxycommand":
                resolved.proxyCommand = value
            default:
                break
            }
        }
        return resolved
    }

    struct JumpSpec: Equatable {
        /// Full `[user@]host` destination usable as an `ssh -G` argument.
        let destination: String
        let host: String?
        let port: Int?
    }

    /// Parse the first hop of a ProxyJump spec: `[user@]host[:port]`, with
    /// optional `[v6::addr]` brackets and comma-separated chains.
    static func parseJumpSpec(_ spec: String) -> JumpSpec? {
        guard let firstHop = spec.split(separator: ",").first else { return nil }
        var hop = firstHop.trimmingCharacters(in: .whitespaces)
        guard !hop.isEmpty else { return nil }

        var user: String?
        if let atIndex = hop.lastIndex(of: "@") {
            user = String(hop[..<atIndex])
            hop = String(hop[hop.index(after: atIndex)...])
        }

        var host = hop
        var port: Int?
        if hop.hasPrefix("[") {
            guard let closeIndex = hop.firstIndex(of: "]") else { return nil }
            host = String(hop[hop.index(after: hop.startIndex)..<closeIndex])
            let remainder = hop[hop.index(after: closeIndex)...]
            if remainder.hasPrefix(":") {
                port = Int(remainder.dropFirst())
            }
        } else if let colonIndex = hop.lastIndex(of: ":"),
                  hop.firstIndex(of: ":") == colonIndex {
            // Exactly one colon: host:port. More than one without brackets is
            // a bare IPv6 address with no port.
            host = String(hop[..<colonIndex])
            port = Int(hop[hop.index(after: colonIndex)...])
        }

        guard !host.isEmpty else { return nil }
        let destination = user.map { "\($0)@\(host)" } ?? host
        return JumpSpec(destination: destination, host: host, port: port)
    }

    private static func runSSHConfigResolution(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(sshResolveTimeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// Attempt a TCP connection to `host:port`, reporting `.reachable` on a
    /// successful handshake and `.unreachable` on refusal, timeout, DNS
    /// failure, or no route.
    static func probeTCP(
        host: String,
        port: Int,
        timeout: TimeInterval = defaultTimeout,
        completion: @escaping (WorkspaceRemoteHostProbeOutcome) -> Void
    ) {
        guard port > 0, port <= 65_535, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            completion(.indeterminate)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        // Both finish paths (state updates via `connection.start(queue:)` and
        // the timeout below) run on the serial `probeQueue`, so the
        // first-finisher latch needs no separate synchronization.
        var finished = false
        func finish(_ outcome: WorkspaceRemoteHostProbeOutcome) {
            guard !finished else { return }
            finished = true
            // NWConnection retains its handler and the handler's context
            // captures the connection; clear it before canceling so each
            // backoff-retry probe doesn't leak a connection.
            connection.stateUpdateHandler = nil
            connection.cancel()
            completion(outcome)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(.reachable)
            case .failed(let error):
                finish(.unreachable(reason: error.localizedDescription))
            case .waiting(let error):
                // NWConnection parks refused/no-route attempts in `.waiting`
                // hoping for a better path; for a quick probe that means the
                // endpoint is not reachable right now.
                finish(.unreachable(reason: error.localizedDescription))
            default:
                break
            }
        }
        connection.start(queue: probeQueue)
        probeQueue.asyncAfter(deadline: .now() + timeout) {
            finish(.unreachable(reason: "probe timed out after \(Int(timeout.rounded()))s"))
        }
    }
}
