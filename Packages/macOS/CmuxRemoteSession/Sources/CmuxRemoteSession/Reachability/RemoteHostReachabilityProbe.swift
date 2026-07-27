public import CmuxRemoteWorkspace
public import Foundation
internal import Network

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
///
/// Lifted from the app's `WorkspaceRemoteHostReachabilityProbe` namespace
/// enum, converted to a value type per the no-namespace-enums convention.
/// Each instance owns its serial callback queue (the legacy static queue was
/// process-wide; the queue only serializes one instance's NWConnection
/// callbacks and timeout latches, so per-instance scope changes nothing
/// observable).
public struct RemoteHostReachabilityProbe: RemoteHostReachabilityProbing {
    static let defaultTimeout: TimeInterval = 2.5
    private static let sshResolveTimeout: TimeInterval = 3.0

    /// Serial queue for NWConnection callbacks and the timeout latch.
    private let probeQueue = DispatchQueue(
        label: "com.cmux.remote-host-reachability",
        qos: .utility
    )
    /// Sleep seam for the probe timeout (legacy `asyncAfter`, converted per
    /// the no-`asyncAfter` rule; the 2.5s delay is identical).
    private let clock: any RemoteProxyRetryClock

    /// Creates a probe.
    /// - Parameter clock: Sleep seam driving the TCP probe timeout
    ///   (production default: the continuous clock).
    public init(clock: any RemoteProxyRetryClock = SystemRemoteProxyRetryClock()) {
        self.clock = clock
    }

    /// Probe the SSH endpoint for `destination`. The completion runs on an
    /// arbitrary queue; callers hop back to their own queue.
    public func probe(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        completion: @escaping @Sendable (RemoteHostProbeOutcome) -> Void
    ) {
        let timeout = Self.defaultTimeout
        // Endpoint resolution shells out to `ssh -G` and can block for up to
        // its timeout; run it on the concurrent utility pool so simultaneous
        // probes from multiple workspaces don't serialize behind it (the
        // serial probeQueue is reserved for NWConnection callbacks).
        DispatchQueue.global(qos: .utility).async {
            guard let endpoint = Self.resolveEndpoint(
                destination: destination,
                port: port,
                identityFile: identityFile,
                sshOptions: sshOptions
            ) else {
                completion(.indeterminate)
                return
            }
            self.probeTCP(
                host: endpoint.host,
                port: endpoint.port,
                timeout: timeout,
                completion: completion
            )
        }
    }

    /// The effective `(host, port)` a destination resolves to.
    struct Endpoint: Equatable {
        let host: String
        let port: Int
    }

    // The parse/resolve helpers are static because they normalize raw ssh
    // configuration text independent of any probe instance (the CmuxCore
    // SSH-option-normalization precedent); they are pinned by tests.

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

    /// The subset of `ssh -G` output the probe cares about.
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

    /// One parsed ProxyJump hop.
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
        // Bounded wait on the real exit signal (the legacy 20ms `usleep`
        // poll loop, converted per the no-sleep-as-sync rule; the 3s upper
        // bound and terminate-on-timeout behavior are identical).
        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard exitSemaphore.wait(timeout: .now() + sshResolveTimeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    // First-finisher latch shared by the NWConnection state handler and the
    // timeout task; both finish paths run on the serial `probeQueue`, so the
    // flag needs no separate synchronization. `@unchecked Sendable` because
    // the compiler cannot see that confinement (the legacy code expressed the
    // same contract with a captured local `var`).
    private final class ProbeFinishLatch: @unchecked Sendable {
        var finished = false
    }

    /// Attempt a TCP connection to `host:port`, reporting `.reachable` on a
    /// successful handshake and `.unreachable` on refusal, timeout, DNS
    /// failure, or no route.
    func probeTCP(
        host: String,
        port: Int,
        timeout: TimeInterval = defaultTimeout,
        completion: @escaping @Sendable (RemoteHostProbeOutcome) -> Void
    ) {
        guard port > 0, port <= 65_535, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            completion(.indeterminate)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        // Both finish paths (state updates via `connection.start(queue:)` and
        // the timeout below) run on the serial `probeQueue`, so the
        // first-finisher latch needs no separate synchronization.
        let latch = ProbeFinishLatch()
        let finish: @Sendable (RemoteHostProbeOutcome) -> Void = { outcome in
            guard !latch.finished else { return }
            latch.finished = true
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
        // Legacy `probeQueue.asyncAfter` timeout, converted to the injected
        // clock per the no-`asyncAfter` rule; the delay is identical and a
        // late wakeup is absorbed by the first-finisher latch.
        let probeQueue = self.probeQueue
        let clock = self.clock
        let milliseconds = Int((timeout * 1000).rounded(.up))
        Task {
            guard (try? await clock.sleep(forMilliseconds: milliseconds)) != nil else { return }
            probeQueue.async {
                finish(.unreachable(reason: "probe timed out after \(Int(timeout.rounded()))s"))
            }
        }
    }
}
