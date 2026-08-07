import Foundation

/// The transports cmux can carry a control stream over.
///
/// A closed set rather than a free-form string, so an unknown value is rejected at the
/// socket boundary instead of becoming an unspawnable host.
enum RemoteTmuxTransportKind: String, Sendable, Equatable, CaseIterable {
    /// Plain ssh over the shared ControlMaster: the default, and today's behavior.
    case ssh
    /// EternalTerminal: keeps its session across a network change, and is spawned under a pty
    /// (see ``RemoteTmuxTransportProfile/requiresPseudoTerminal`` for what that does and does not buy).
    case et

    /// Parses a user-supplied value, rejecting anything unrecognized.
    static func parse(_ raw: String?) -> RemoteTmuxTransportKind? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return .ssh }
        return RemoteTmuxTransportKind(rawValue: raw)
    }

    /// The port this transport actually uses, given a host's optional override.
    ///
    /// One place resolves the default so identity and argv cannot disagree: hashing an unset port
    /// separately from the explicit value it resolves to gave one host two controller keys.
    func resolvedTransportPort(_ configured: Int?) -> Int {
        switch self {
        case .ssh: return configured ?? 22
        case .et: return configured ?? 2022
        }
    }

    /// Whether naming a broker means anything for this transport.
    ///
    /// ssh ignores one on purpose, so a request for it has to be refused at the boundary rather than
    /// accepted and dropped — accepting it would reach the host directly while the user asked for a
    /// specific route.
    var usesTransportBroker: Bool {
        switch self {
        case .ssh: return false
        case .et: return true
        }
    }

    /// The profile that carries this transport.
    func profile(
        port: Int?,
        terminalPath: String? = nil,
        broker: RemoteTmuxTransportBroker? = nil
    ) -> RemoteTmuxTransportProfile {
        switch self {
        case .ssh:
            // A broker is ignored for ssh on purpose. ssh already has ProxyCommand/ProxyJump for
            // exactly this, configured in ssh_config where the user's other host settings live, so
            // a second mechanism here would only add a way for the two to disagree.
            return RemoteTmuxSSHTransportProfile()
        case .et:
            // etserver listens on 2022 by default, and a host's `port` means "the port of
            // this host's transport" — for et that is etserver's, not sshd's.
            // A terminal path has to be sent: `etterminal` is not on a non-interactive ssh PATH on
            // macOS, and without the flag et fails with "Error starting ET process through ssh".
            // Measured — dropping the flag entirely was worse than the literal it replaced.
            //
            // So it is resolved rather than assumed. `RemoteTmuxController` probes the host once
            // over the ssh one-shot channel and stores the answer; this default is only the
            // starting point for a host nobody has probed yet.
            return RemoteTmuxETTransportProfile(
                port: resolvedTransportPort(port),
                remoteTerminalPath: terminalPath ?? RemoteTmuxETTransportProfile.defaultRemoteTerminalPath,
                // Forwarded, and worth stating why this line is load-bearing: omitting it left the
                // profile with no broker, so a brokered host silently built the direct argv —
                // endpoint flags and all — and would have failed against a wrapper that rejects a
                // client flag before the destination. Caught by
                // `brokeredArgvPutsBrokerFlagsFirstAndDropsEndpointFlags`.
                broker: broker
            )
        }
    }
}

/// How a control stream opens its tmux session.
///
/// A mode rather than a `create` flag, because there are three shapes and they are not two
/// booleans' worth of choice: attaching to a session that must already exist, attach-or-create,
/// and attach-or-create at an explicit size. Every transport builds its remote command from the
/// same token list here, so the shapes cannot drift apart between profiles.
enum RemoteTmuxControlAttachMode: Sendable, Equatable, Hashable {
    /// `attach-session -t <name>`: the session has to exist. Every reconnect uses this, so a
    /// session killed during an outage ends the connection instead of being silently recreated.
    case attach
    /// `new-session -A -s <name>`: attach when it exists, create it otherwise.
    case attachOrCreate
    /// `new-session -A -s <name> -x <cols> -y <rows>`: attach or create at an explicit size.
    ///
    /// The size is what the hidden view session needs. A session created without it starts at
    /// 80x24, so its first window flashes at that size before the client's first
    /// `refresh-client -C` lands.
    case attachOrCreateSized(columns: Int, rows: Int)

    /// The mode a caller's `createIfMissing` flag means, so the socket boundary's length check
    /// and the connection that spawns the command cannot measure different shapes. They did:
    /// the boundary checked `.attach` while `create: true` built the longer `new-session -A -s`,
    /// and an 890-byte name passed the boundary's 890-byte bound before `spawnProcess` computed
    /// 929 against a 928-byte budget and threw `launchFailed`.
    static func forCreateIfMissing(_ createIfMissing: Bool) -> RemoteTmuxControlAttachMode {
        createIfMissing ? .attachOrCreate : .attach
    }

    /// The tmux arguments for this mode, including the `-CC` client flag.
    ///
    /// One list for every transport: ssh wraps it in the PATH resolver, et quotes it into a login
    /// shell, and both then agree on what a mode means.
    func tmuxArguments(sessionName: String) -> [String] {
        switch self {
        case .attach:
            return ["-CC", "attach-session", "-t", sessionName]
        case .attachOrCreate:
            return ["-CC", "new-session", "-A", "-s", sessionName]
        case let .attachOrCreateSized(columns, rows):
            return [
                "-CC", "new-session", "-A", "-s", sessionName,
                "-x", String(columns), "-y", String(rows),
            ]
        }
    }
}

/// How a remote tmux control stream and one-shot commands are carried to a host.
///
/// Today there is exactly one implementation and it is ssh, so this changes no behavior.
/// It exists because the choice of transport is currently spelled out at the point of use —
/// `Process` is handed `ssh` and `host.controlModeArguments(…)` directly — and any transport
/// that keeps a session alive across a network change (EternalTerminal, mosh) cannot be
/// introduced without first naming that decision.
///
/// The split is between *argv* and *execution*: this decides what to run, while
/// ``RemoteTmuxSSHTransport`` keeps owning process spawning, the shared ControlMaster, and
/// stderr classification. Keeping execution out means a second transport does not have to
/// reimplement any of that.
protocol RemoteTmuxTransportProfile: Sendable {
    /// The binary that carries the connection.
    func executablePath() -> String

    /// argv for the long-lived `tmux -CC` control stream.
    func controlStreamArgv(
        host: RemoteTmuxHost,
        sessionName: String,
        mode: RemoteTmuxControlAttachMode
    ) -> [String]

    /// argv for a one-shot remote command (discovery, mutations).
    func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String]

    /// Whether the transport needs a pseudo-terminal rather than pipes.
    ///
    /// This used to say that `et` writes nothing at all on pipes, so a pty was the difference
    /// between working and silent. That is false, and it mattered: it justified the wrapper for a
    /// reason that would not survive contact with anyone checking it.
    ///
    /// What actually happens, from et's own source and confirmed by measurement. The client builds
    /// a local console unless `-N` is passed (`TerminalClientMain.cpp`: `if (!result.count("N"))
    /// console.reset(new PsuedoTerminalConsole())`), and that console's `tcgetattr`/`cfmakeraw`/
    /// `tcsetattr` on fd 0 are called *without checking their return values*
    /// (`PsuedoTerminalConsole.hpp`). On a pipe those calls simply fail and the data path carries
    /// on, so control mode is reached over pipes — measured, including with no controlling terminal
    /// at all, which is precisely how cmux spawns it.
    ///
    /// The pty earns its place for a different reason. With no usable termios the client cannot put
    /// the terminal in raw mode, so the same session's stream arrives far larger, padded
    /// with full-screen redraws. Two measurements, quoted with their conditions rather than as a
    /// bare multiple, because they came from different setups and a lone ratio hides which:
    /// 1324 bytes with a pty vs 44576 without, one session against a loopback server; and
    /// 1006 vs 44628 for the same session spawned under `setsid` with no controlling terminal.
    /// cmux parses that stream and budgets its buffers against it, so the wrapper is about a
    /// bounded, clean stream rather than about existence.
    ///
    /// `-N` is not the alternative it looks like. It suppresses the console, and the remote's output
    /// is written only when one exists (`TerminalClient.cpp`: `if (console) console->write(s)`), so
    /// the stream is received and discarded. Measured: 1019 bytes and one `%begin` without it,
    /// 41 bytes and none with it. A transport that reports `true` here needs the pty.
    var requiresPseudoTerminal: Bool { get }

    /// How far past the deliverable line length this transport's remote command would be, or nil
    /// when it fits.
    ///
    /// Exists so the check can live at the single point every caller passes through. The socket
    /// boundary already refuses an over-long session name, but only on `remote.tmux.attach`; the
    /// CLI drives the mirror and window RPCs, whose names come from discovery rather than a
    /// parameter, so they never reach it. A real session with a long name then produced an attach
    /// that timed out with nothing to explain it.
    ///
    /// Default nil, because a transport that `exec`s its command has no such limit — only one that
    /// types it into a terminal does.
    func commandLengthOverrun(
        sessionName: String,
        mode: RemoteTmuxControlAttachMode
    ) -> (actual: Int, budget: Int)?

    /// Whether the transport recovers from network loss by itself.
    ///
    /// This is the property that changes cmux's behavior rather than just its argv. cmux
    /// treats stdout EOF as "the stream died, respawn with backoff". A transport that
    /// reconnects internally produces no EOF for a network drop — the stream pauses and
    /// resumes — so respawning on a stall would throw away the session it was about to
    /// recover. Such a transport needs a liveness check (process alive plus a control-mode
    /// round-trip) instead of an EOF trigger.
    var reconnectsInternally: Bool { get }

    /// Whether the remote end keeps running after the local client process exits.
    ///
    /// This decides whether cmux has to detach in tmux's own terms. Killing an ssh client closes
    /// the pty it handed tmux, so tmux reaps that control client by itself and tearing the
    /// transport down is a complete detach. et is built to survive a dead client: `etterminal`
    /// stays up holding the pty so a later `et` can resume it, which also means the tmux control
    /// client stays attached to the session.
    ///
    /// Measured on 2026-07-22 with five mirrors of one host: closing one mirror left 4 local `et`
    /// clients (cmux's teardown did land) against 5 `etterminal` processes and 5 attached control
    /// clients. Five more clients from an app that had already quit were still attached 46 minutes
    /// later. Stale clients accumulate one per closed mirror, and because a window's usable size
    /// is bounded by the smallest attached client, a stale narrow one can clamp a live mirror.
    var remoteHalfSurvivesLocalExit: Bool { get }
}

extension RemoteTmuxTransportProfile {
    /// No limit unless a profile declares one.
    func commandLengthOverrun(
        sessionName: String,
        mode: RemoteTmuxControlAttachMode
    ) -> (actual: Int, budget: Int)? { nil }
}

/// What end-of-stream on the control connection means.
///
/// cmux's recovery is built on stdout EOF: the stream ends, so respawn with backoff.
///
/// The tempting rule is that a transport owning its own reconnection does not end for a network
/// drop, so its exit must mean the session ended. Measured against et 6.2.11+7, that is false:
/// restarting only `etserver` closes the stream while `tmux has-session` still succeeds. Acting on
/// it discarded mirrors whose sessions were alive and reattachable.
///
/// EOF cannot distinguish "the transport died" from "the session died", for any transport, so this
/// does not try. Reattaching answers the question: the reconnect path already classifies a genuinely
/// gone session from what the reattach reports. The failure such a transport still needs watching
/// for is the one EOF never reports at all — alive but wedged.
enum RemoteTmuxStreamEndDisposition: Sendable, Equatable {
    /// cmux owns recovery: respawn the transport with backoff.
    case reconnect
    /// The transport owned recovery, so its exit is terminal.
    case sessionOver

    /// What EOF on the control stream means.
    ///
    /// It used to branch on who owns reconnection, and that branch was wrong (see this type's
    /// documentation). The distinction that does hold is whether the stream ever worked:
    ///
    /// - reached control mode, then ended: something was there and may still be. Reconnect, and let
    ///   the reattach report whether the session is gone.
    /// - never reached control mode: the transport failed to *start*. There is no session behind it
    ///   to preserve, and retrying only hides the reason — measured, it turned "tmux control stream
    ///   ended before attach" into an opaque 60-second attach timeout.
    static func forStreamEnd(hasReachedControlMode: Bool) -> RemoteTmuxStreamEndDisposition {
        hasReachedControlMode ? .reconnect : .sessionOver
    }
}

/// A wrapper that fronts a transport client, for hosts that are not directly reachable.
///
/// Some networks put a broker between the client and the host: the broker resolves how to get
/// there — a tunnel, an agent socket, a jump relay, a short-lived credential — and then launches
/// the real client with whatever endpoint it produced. Those details are the broker's business,
/// and a transport that tries to reconstruct them ends up encoding one site's topology.
///
/// So cmux does not reconstruct them. A brokered host names the wrapper and its flags, and cmux
/// invokes `<executable> <leadingArguments> <destination> <client args…>`. The broker supplies the
/// port, the tunnel and the credentials; cmux supplies only the remote command. Measured against a
/// real broker: this shape reaches control mode where a direct connection cannot reach the host at
/// all.
///
/// `nil` means today's behavior: connect directly.
struct RemoteTmuxTransportBroker: Sendable, Equatable {
    /// The wrapper to run instead of the transport client.
    let executable: String

    /// Flags the wrapper needs *before* the destination, e.g. which client to launch and whether
    /// to fall back. Ordering matters to most brokers, so this is a list rather than a set.
    let leadingArguments: [String]

    init(executable: String, leadingArguments: [String] = []) {
        self.executable = executable
        self.leadingArguments = leadingArguments
    }

    /// Whether this broker supplies the transport's own endpoint flags.
    ///
    /// Always true today, and named rather than assumed: a broker that resolves reachability is by
    /// definition the thing that knows the port and the helper path, so cmux passing its own would
    /// fight it. Keeping it explicit means a future broker that needs cmux's values can say so.
    var suppliesEndpointFlags: Bool { true }
}

/// The brokers a user has declared, keyed by the name a caller refers to them by.
///
/// REACHABLE BY A USER, end to end, and this comment is kept exact on purpose because it has been
/// wrong in both directions before — it spent a while claiming the opposite after the last piece
/// landed, which is the worse direction to be wrong in for a seam that launches a process.
///
/// The whole path, so it can be checked rather than trusted: a user declares brokers under
/// `remoteTmux.brokers`, `CmuxConfigFile` decodes them and publishes the registry plus the reasons
/// for any it refused (``RemoteTmuxBrokerSnapshot``), the socket boundary reads a `transport_broker`
/// name and refuses the host outright when it does not resolve
/// (``TerminalController/remoteTmuxHost(from:selectBroker:)``), `cmux ssh-tmux --broker <name>`
/// forwards that name, ``select(requestedName:registry:rejected:)`` makes the trust decision,
/// ``RemoteTmuxETTransportProfile`` builds the argv, and ``isAcceptableExecutable`` is applied to
/// `executablePath()` before `Process` runs it.
///
/// So the guarantees that matter are the lookup and that spawn check, not the absence of callers.
///
/// Why the design is a named registry rather than an inline broker in the RPC: the socket is
/// reachable by anything running as the user, so accepting an executable and arguments there would
/// be a strictly larger local-execution surface than the `-oProxyCommand=…` injection the boundary
/// already refuses. Naming a config entry means the socket can only pick something the user wrote
/// down, and validation reduces to a lookup that either finds a usable entry or explains why not.
struct RemoteTmuxBrokerRegistry: Sendable, Equatable {
    private let brokers: [String: RemoteTmuxTransportBroker]

    init(_ brokers: [String: RemoteTmuxTransportBroker] = [:]) {
        self.brokers = brokers
    }

    var isEmpty: Bool { brokers.isEmpty }

    /// Resolves a name, or nil if it was never declared.
    ///
    /// A pure lookup so the trust decision is testable without a config file or a socket. An
    /// unknown name must be refused rather than defaulted: silently connecting directly when the
    /// user asked for a broker would reach a host by a route they did not choose, or fail with an
    /// error that points at the network instead of at the typo.
    func broker(named name: String) -> RemoteTmuxTransportBroker? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return brokers[trimmed]
    }

    /// Whether an executable is fit to be launched as a broker.
    ///
    /// Absolute paths only, and not merely for tidiness: the pty wrapper resolves its argument
    /// against the app's PATH, which for a GUI app is not the user's, so a bare name fails in a
    /// way that looks like the host being unreachable. Hidden and control characters are refused
    /// on the same grounds the destination refuses them.
    static func isAcceptableExecutable(_ path: String, fileExists: (String) -> Bool) -> Bool {
        guard path.hasPrefix("/") else { return false }
        guard !path.unicodeScalars.contains(where: {
            $0.properties.isDefaultIgnorableCodePoint || ($0.value < 0x20) || $0.value == 0x7f
        }) else { return false }
        return fileExists(path)
    }
}

/// A broker as a user declares it in `~/.config/cmux/cmux.json`, under `remoteTmux.brokers`.
///
/// Declared by name so the control socket can only ever pick something already written down. The
/// socket is reachable by anything running as the user, and letting it name an executable inline
/// would be a wider local-execution surface than the `-oProxyCommand=…` injection the boundary
/// already refuses.
struct CmuxRemoteTmuxBrokerDefinition: Codable, Hashable, Sendable {
    /// Absolute path to the wrapper. Absolute because the pty wrapper resolves its argument
    /// against the app's PATH, which for a GUI app is not the user's.
    var executable: String

    /// Flags the wrapper needs before the destination. A list, because order matters to a broker
    /// that parses its own flags and forwards the rest.
    var arguments: [String]

    private enum CodingKeys: String, CodingKey {
        case executable, arguments
    }

    init(executable: String, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        executable = try container.decode(String.self, forKey: .executable)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
    }
}

/// The `remoteTmux` section of the config file.
struct CmuxRemoteTmuxConfigDefinition: Codable, Hashable, Sendable {
    var brokers: [String: CmuxRemoteTmuxBrokerDefinition]

    private enum CodingKeys: String, CodingKey {
        case brokers
    }

    init(brokers: [String: CmuxRemoteTmuxBrokerDefinition] = [:]) {
        self.brokers = brokers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        brokers = try container.decodeIfPresent(
            [String: CmuxRemoteTmuxBrokerDefinition].self, forKey: .brokers
        ) ?? [:]
    }
}

/// What a caller asking for a broker by name gets back.
///
/// Four cases rather than an optional, because the three failures need different words. "Never
/// declared" is a typo or a missing config entry; "declared but unusable" is a path problem the
/// user can fix; and connecting directly when a broker was asked for is not an option at all —
/// that reaches the host by a route the user did not choose, and any later failure would point at
/// the network instead of at the real cause.
enum RemoteTmuxBrokerSelection: Sendable, Equatable {
    /// No broker was asked for; the direct argv applies.
    case none
    case resolved(RemoteTmuxTransportBroker)
    case unknown(name: String)
    case unusable(name: String, reason: String)
    /// The name itself could never match a config key.
    case malformed(reason: String)
}

extension RemoteTmuxBrokerRegistry {
    /// Builds a registry from configuration, keeping the entries fit to launch and returning the
    /// reasons for the rest.
    ///
    /// Unusable entries are kept out of the registry but remembered, so selecting one says why it
    /// cannot be used instead of claiming it was never declared. Silently dropping them would turn
    /// a fixable path mistake into a phantom typo.
    static func make(
        from definition: CmuxRemoteTmuxConfigDefinition,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> (registry: RemoteTmuxBrokerRegistry, rejected: [String: String]) {
        var usable: [String: RemoteTmuxTransportBroker] = [:]
        var rejected: [String: String] = [:]
        for (rawName, entry) in definition.brokers {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let executable = entry.executable.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isAcceptableExecutable(executable, fileExists: fileExists) else {
                rejected[name] = executable.hasPrefix("/")
                    ? "no executable file at \(executable)"
                    : "executable must be an absolute path, got \(executable.isEmpty ? "an empty value" : executable)"
                continue
            }
            // An argument that looks like a flag is fine — that is what a broker takes — but a
            // hidden or control character never is, on the same grounds the destination refuses
            // them: it can smuggle terminal escapes or obscure what is really being run.
            if let bad = entry.arguments.first(where: { Self.hasHiddenCharacter($0) }) {
                rejected[name] = "argument contains a control or hidden character: \(bad.debugDescription)"
                continue
            }
            usable[name] = RemoteTmuxTransportBroker(
                executable: executable, leadingArguments: entry.arguments
            )
        }
        return (RemoteTmuxBrokerRegistry(usable), rejected)
    }

    /// Resolves what a caller asked for against what the user declared.
    ///
    /// A pure function of its inputs so the trust decision is testable without a config file, a
    /// socket, or a filesystem.
    static func select(
        requestedName: String?,
        registry: RemoteTmuxBrokerRegistry,
        rejected: [String: String] = [:]
    ) -> RemoteTmuxBrokerSelection {
        guard let requestedName else { return .none }
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .none }
        if hasHiddenCharacter(name) {
            return .malformed(reason: "broker name contains a control or hidden character")
        }
        if let broker = registry.broker(named: name) { return .resolved(broker) }
        if let reason = rejected[name] { return .unusable(name: name, reason: reason) }
        return .unknown(name: name)
    }

    /// Control, format and separator scalars, refused wherever a value reaches a command line.
    static func hasHiddenCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            if scalar.properties.isDefaultIgnorableCodePoint { return true }
            if scalar.value < 0x20 || scalar.value == 0x7f { return true }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return false
            }
        }
    }
}

/// The declared brokers, readable from the socket's parsing path.
///
/// The config store lives on the main actor and the socket parses parameters off it, so the
/// resolved registry is published here rather than reached across actors mid-parse. That keeps the
/// trust decision where every other check on those parameters already happens — a broker that
/// cannot be resolved is refused at the boundary, not deep inside a connection attempt.
final class RemoteTmuxBrokerSnapshot: @unchecked Sendable {
    static let shared = RemoteTmuxBrokerSnapshot()

    private let lock = NSLock()
    private var registry = RemoteTmuxBrokerRegistry()
    private var rejections: [String: String] = [:]

    /// Replaces the snapshot. Called on every config load, so editing the file takes effect on the
    /// next connection rather than needing a restart.
    func update(registry: RemoteTmuxBrokerRegistry, rejections: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        self.registry = registry
        self.rejections = rejections
    }

    func select(requestedName: String?) -> RemoteTmuxBrokerSelection {
        lock.lock()
        let currentRegistry = registry
        let currentRejections = rejections
        lock.unlock()
        return RemoteTmuxBrokerRegistry.select(
            requestedName: requestedName, registry: currentRegistry, rejected: currentRejections
        )
    }
}

/// A command to run before opening a connection to a host.
///
/// Some hosts need a step cmux has no business knowing about: minting a short-lived
/// credential, unlocking an agent, refreshing a token. Rather than teaching cmux any of
/// them, a host can carry a command, run as `<command> <destination>`.
///
/// Two rules come out of wiring one of these up for real:
///
/// - It runs once per connection, not once per command. Anything minting a single-use
///   credential must not race itself — two mints can invalidate each other — so the right
///   home is the single-flight path that opens the shared master, not a per-command hook.
/// - A non-zero exit is not fatal. cmux proceeds and lets the connection fail on its own
///   terms, so a broken hook cannot make a host unreachable.
struct RemoteTmuxPreConnectHook: Sendable, Equatable {
    /// The executable to run. `nil` means today's behavior: no hook.
    let command: String?

    init(command: String? = nil) {
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.command = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// The argv to run for `destination`, or nil when no hook is configured.
    func argv(destination: String) -> [String]? {
        guard let command else { return nil }
        return [command, destination]
    }

    /// Whether a hook's exit status should abort the connection. It never should: see the
    /// type's documentation.
    func shouldAbortConnection(onExitCode code: Int32) -> Bool { false }
}

/// The ssh transport: current behavior, and the default.
struct RemoteTmuxSSHTransportProfile: RemoteTmuxTransportProfile {
    /// Idle lifetime of the shared master, matching ``RemoteTmuxSSHTransport``'s default so
    /// one-shot argv built here is identical to what the transport builds for itself.
    let controlPersistSeconds: Int

    init(controlPersistSeconds: Int = 180) {
        self.controlPersistSeconds = controlPersistSeconds
    }

    func executablePath() -> String {
        RemoteTmuxHost.defaultSSHExecutablePath()
    }

    func controlStreamArgv(
        host: RemoteTmuxHost,
        sessionName: String,
        mode: RemoteTmuxControlAttachMode
    ) -> [String] {
        host.controlModeArguments(sessionName: sessionName, mode: mode)
    }

    func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String] {
        // `--` ends ssh option parsing so a destination beginning with `-` (e.g.
        // `-oProxyCommand=…`) can never be consumed as an ssh option.
        host.sshControlArguments(controlPersistSeconds: controlPersistSeconds, batchMode: true)
            + ["--", host.destination, remoteCommand]
    }

    /// ssh does not: a dropped connection ends the process, and cmux respawns it.
    var reconnectsInternally: Bool { false }

    /// ssh is happy on pipes, which is what cmux spawns today.
    var requiresPseudoTerminal: Bool { false }

    /// Killing the ssh client closes tmux's pty, so tmux drops the control client itself.
    var remoteHalfSurvivesLocalExit: Bool { false }
}

/// How cmux gives a transport a controlling terminal.
///
/// cmux spawns its control stream on pipes, which a terminal client like EternalTerminal
/// refuses to work with. Rather than reimplement `posix_openpt`/`grantpt`/`TIOCSCTTY`
/// plumbing, wrap the transport in the system's own pty allocator, which is also how the
/// behavior was verified by hand.
///
/// Two measured facts make this safe for a control protocol:
///
/// - The pty echoes whatever cmux writes to stdin. Those echoed lines are not control-mode
///   notifications, so the parser ignores them; they cost bytes, not correctness.
/// - Anything written before the control stream is up is consumed by the transport's *login
///   shell*, not by tmux. cmux already withholds commands until `%enter`, so this is
///   already respected — but it is why that ordering is load-bearing rather than incidental.
enum RemoteTmuxPseudoTerminal {
    /// BSD `script` runs a command with a pty attached and copies the session to a file;
    /// `/dev/null` discards the copy while keeping the pty.
    static let allocatorPath = "/usr/bin/script"

    /// Wraps a transport invocation so the child gets a tty on stdin/stdout/stderr.
    static func wrap(executable: String, arguments: [String]) -> [String] {
        ["-q", "/dev/null", executable] + arguments
    }
}

/// EternalTerminal: a transport that keeps its session across a network change.
///
/// Every claim here was measured against et 6.2.11 on a loopback `etserver`, because the
/// differences from ssh are not the kind you can read off `--help`:
///
/// - **It is spawned under a pty.** Not because it is silent on pipes — it is not, measured — but
/// because without usable terminal modes the stream arrives padded with full-screen redraws.
/// See ``RemoteTmuxTransportProfile/requiresPseudoTerminal``.
/// - **It types the command into a login shell** rather than exec'ing it, appending
///   `; exit`. A real `tmux -CC` stream therefore arrives after ~1.2 KB of preamble: the
///   echoed command line, then prompt escapes, and only then `%begin`. cmux's parser
///   already tolerates this (unrecognized lines yield no messages) and already strips the
///   pty's `\r`, so the protocol survives — but the preamble is not optional, it is what
///   this transport always does.
/// - **It reconnects internally**, so a dropped network does not end the process. On a real
///   session end the client first attempts a reconnect and only then reports the session
///   gone, which is why EOF must mean "over" rather than "respawn" here.
/// - **`-x` / `--kill-other-sessions` must never be passed**: it kills every session that
///   user has on the host, not just stale ones.
struct RemoteTmuxETTransportProfile: RemoteTmuxTransportProfile {
    /// Where `et` may live, in preference order. Apple Silicon Homebrew installs under
    /// `/opt/homebrew`, Intel under `/usr/local`, Linux under `/usr` — a single literal path is a
    /// claim about someone else's machine, and hardcoding `/usr/local/bin` made this transport
    /// unusable on a standard Apple Silicon install.
    static let clientSearchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    /// Used when nothing is found, matching et's own documented install location.
    ///
    /// NOT the bare name `et`: the control stream is spawned through `/usr/bin/script`, which
    /// resolves its argument against the *app's* PATH, and a GUI app's PATH cannot be relied on.
    /// Measured — `script -q /dev/null et --version` under a minimal PATH reports
    /// `script: et: No such file or directory`, the stream ends immediately, and end-of-stream now
    /// means reconnect, so the failure surfaces as a 60-second attach timeout with no error rather
    /// than as "et not found".
    static let defaultClientPath = "/usr/local/bin/et"

    /// The first `et` that exists on PATH or in a known install directory.
    static func resolveClientExecutable(
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        pathValue: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> String {
        let fromPath = (pathValue ?? "").split(separator: ":").map(String.init)
        for directory in fromPath + clientSearchDirectories {
            let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let candidate = URL(fileURLWithPath: trimmed).appendingPathComponent("et").path
            if fileExists(candidate) { return candidate }
        }
        return defaultClientPath
    }

    /// Longest line a remote login shell will accept: `MAX_CANON`, which is 1024 on macOS.
    ///
    /// et types the command into a pty rather than exec'ing it, so this is a hard delivery limit
    /// and not a style guide: a longer line never completes, the shell runs nothing, and the attach
    /// dies on a timeout with nothing to explain it.
    ///
    /// The value is the smaller of the platforms cmux reaches, deliberately. It is 4096 on Linux,
    /// so a bound of 1024 is safe against either — but only as a *starting* figure, because the
    /// whole line is not cmux's to spend. See ``deliverableCommandBytes``.
    static let maxCanonicalLineBytes = 1024

    /// How much of that line cmux may actually fill.
    ///
    /// Measured, because assuming the whole line was available was wrong: against et 6.2.11+7 on
    /// macOS, delivery stops between 953 and 1016 bytes, not at 1024. et appends `; exit` to
    /// whatever it is given and the shell's own line editing costs more on top, so roughly 70
    /// bytes of a 1024-byte line are already spent before cmux's command starts. A budget compared
    /// against the raw `MAX_CANON` therefore passes its own check and still gets truncated, which
    /// is the failure this constant exists to prevent.
    ///
    /// The allowance is rounded up from the measured 71 bytes to absorb a longer prompt or a
    /// noisier shell. `scripts/remote-tmux-et-conformance.sh` re-measures the real threshold on
    /// each run and fails if this budget no longer fits inside it, so the number cannot quietly
    /// drift away from the transport again.
    static let transportLineOverheadAllowanceBytes = 96

    /// Bytes available for the remote command itself.
    static var deliverableCommandBytes: Int {
        max(0, maxCanonicalLineBytes - transportLineOverheadAllowanceBytes)
    }

    /// Longest session name whose attach command still fits one deliverable line.
    ///
    /// Derived from the command this profile actually builds rather than guessed, so it cannot
    /// drift away from it. tmux itself accepts names far longer than this — roughly 1000 bytes —
    /// which is why an unbounded name reached et and silently delivered nothing.
    static func maxSessionNameBytes(mode: RemoteTmuxControlAttachMode = .attach) -> Int {
        let overhead = controlStreamRemoteCommand(sessionName: "", mode: mode).utf8.count
        return max(0, deliverableCommandBytes - overhead - 1)
    }

    /// Where `etterminal` is looked for on the remote, in preference order.
    ///
    /// Sent explicitly because a non-interactive ssh on macOS does not have it on PATH — which is
    /// also why `et` ships `--macserver` at all. The list exists so a host can be probed instead
    /// of assumed: Apple Silicon Homebrew, Intel Homebrew, then Linux packages.
    static let remoteTerminalCandidates = [
        "/opt/homebrew/bin/etterminal",
        "/usr/local/bin/etterminal",
        "/usr/bin/etterminal",
    ]

    /// Used until a host has been probed. Matches what `et --macserver` would send, so an
    /// unprobed host behaves as before rather than worse.
    static let defaultRemoteTerminalPath = "/usr/local/bin/etterminal"

    /// A shell command that prints the first candidate that exists on the remote.
    ///
    /// Short by construction: it is delivered the same way every other et command is, so it is
    /// subject to the same canonical-line limit.
    static func remoteTerminalProbeCommand() -> String {
        "command -v etterminal || " + remoteTerminalCandidates
            .map { "([ -x \($0) ] && echo \($0))" }
            .joined(separator: " || ")
    }

    /// etserver's default port is 2022, not ssh's 22.
    let port: Int
    /// `et` binary path.
    let executable: String
    /// Set when the host is reached through a wrapper rather than directly.
    let broker: RemoteTmuxTransportBroker?
    /// Path to `etterminal` on the server, needed when it is not on the remote PATH — which
    /// is the case for a macOS server, where `--macserver` exists to set exactly this.
    let remoteTerminalPath: String?

    init(
        port: Int = 2022,
        executable: String? = nil,
        remoteTerminalPath: String? = nil,
        broker: RemoteTmuxTransportBroker? = nil
    ) {
        self.broker = broker
        self.port = port
        self.executable = executable ?? Self.resolveClientExecutable()
        self.remoteTerminalPath = remoteTerminalPath
    }

    /// The remote command this profile runs, in one place so the length bound above is derived
    /// from the same string that is actually sent.
    ///
    /// The shape comes from ``RemoteTmuxControlAttachMode``, which both transports share. It used
    /// to be built here as `new-session -t <name>` for the create case, and that is a different
    /// command than it looks: `-t` on `new-session` groups the new session with an existing one
    /// rather than naming it, so it neither created a missing session nor attached to the named
    /// one.
    static func controlStreamRemoteCommand(
        sessionName: String, mode: RemoteTmuxControlAttachMode
    ) -> String {
        (["tmux"] + mode.tmuxArguments(sessionName: sessionName))
            .map(RemoteTmuxHost.shellSingleQuoted)
            .joined(separator: " ")
    }

    func executablePath() -> String { broker?.executable ?? executable }

    func controlStreamArgv(
        host: RemoteTmuxHost,
        sessionName: String,
        mode: RemoteTmuxControlAttachMode
    ) -> [String] {
        // Plain `tmux`, not the PATH resolver ssh needs, and the reason is a hard limit rather
        // than a preference. `et` does not exec the command: it types it into a login shell and
        // appends `; exit`. That shell reads from a pty in canonical mode, which delivers at
        // most MAX_CANON (1024 on macOS) bytes per line, and the resolver is ~1113 bytes. The
        // line never completes, so the shell runs nothing and the stream sits silent until the
        // attach times out — measured against et 6.2.11.
        //
        // Dropping the resolver is safe precisely because it is a login shell: it has the user's
        // full PATH, so it finds tmux itself. ssh is the opposite case, running a non-login shell
        // with a minimal PATH, which is why that profile still needs the resolver.
        let remote = Self.controlStreamRemoteCommand(sessionName: sessionName, mode: mode)
        // A brokered host takes a different argv shape, not extra flags on this one.
        //
        // The wrapper parses its own flags up to the destination and forwards everything after
        // it to the client, so ordering is load-bearing rather than stylistic: a client flag
        // placed before the destination is rejected outright, and the wrapper exits without
        // connecting. Measured against a real broker — `-p 2022` ahead of the destination gives
        // "flag provided but not defined: -p" and exit 2, while the same flag after it is
        // accepted and passed along.
        //
        // The endpoint flags are dropped rather than reordered. The broker resolved the
        // endpoint; it already knows the port and the helper path, and handing it cmux's
        // guesses would override the values it just worked out.
        if let broker, broker.suppliesEndpointFlags {
            return broker.leadingArguments + [host.destination, "-c", "exec \(remote)"]
        }
        // Arguments only: the executable is supplied separately (see ``executablePath()``),
        // exactly as the ssh profile does. Including it here would pass `et` twice.
        var argv = ["-p", String(port)]
        if let remoteTerminalPath {
            argv += ["--terminal-path", remoteTerminalPath]
        }
        // et bootstraps over ssh before its own protocol takes over, and it does not inherit the
        // host's ssh settings from anywhere. Passing them through `--ssh-option` is what makes
        // `--port 2222 --identity /key --transport et` reach the same sshd the ssh preflight just
        // used; without it the preflight succeeds and et's bootstrap fails against defaults.
        //
        // `host.port` is the SSH port here, distinct from `port` above, which is etserver's.
        if let sshPort = host.port {
            argv += ["--ssh-option", "Port=\(sshPort)"]
        }
        if let identityFile = host.identityFile {
            argv += ["--ssh-option", "IdentityFile=\(identityFile)"]
        }
        // `exec` so the login shell does not linger as a parent of tmux.
        argv += ["-c", "exec \(remote)", host.destination]
        return argv
    }

    /// One-shot commands keep riding ssh's shared master: it is already single-flighted for
    /// the cold-start burst, and that logic has nothing to do with how the `-CC` stream is
    /// carried.
    func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String] {
        RemoteTmuxSSHTransportProfile().oneShotArgv(host: host, remoteCommand: remoteCommand)
    }

    var reconnectsInternally: Bool { true }
    var requiresPseudoTerminal: Bool { true }

    /// `etterminal` outlives the local client on purpose — that is what makes a resume possible —
    /// so the tmux client it holds has to be detached before the transport goes away.
    var remoteHalfSurvivesLocalExit: Bool { true }

    /// et types its command into a canonical-mode pty, so an over-long line is never delivered.
    /// Measured against real et: delivery stops between 1016 and 1080 bytes of total command line
    /// on a host whose MAX_CANON is 1024, so the budget deliberately sits below it.
    func commandLengthOverrun(
        sessionName: String,
        mode: RemoteTmuxControlAttachMode
    ) -> (actual: Int, budget: Int)? {
        let actual = Self.controlStreamRemoteCommand(sessionName: sessionName, mode: mode).utf8.count
        let budget = Self.deliverableCommandBytes
        return actual > budget ? (actual: actual, budget: budget) : nil
    }
}

/// Owns the per-endpoint ``RemoteTmuxSSHTransport`` instances ``RemoteTmuxController``
/// uses for SSH discovery, keyed by ``RemoteTmuxHost/connectionHash`` (destination +
/// port + identity).
///
/// Factored out of the controller so the get-or-create lifecycle and the scattered
/// dictionary bookkeeping live behind a small `@MainActor` surface. It only manages
/// the transport handles; it deliberately does NOT own the `ssh -O exit`
/// (``RemoteTmuxSSHTransport/spawnControlMasterExit(host:)``) teardown, which the
/// controller sequences around its own `await` gaps.
@MainActor
final class RemoteTmuxTransportRegistry {
    private var transports: [String: RemoteTmuxSSHTransport] = [:]

    /// Returns (creating if needed) the transport for a host.
    func transport(for host: RemoteTmuxHost) -> RemoteTmuxSSHTransport {
        if let existing = transports[host.connectionHash] {
            return existing
        }
        let transport = RemoteTmuxSSHTransport(host: host)
        transports[host.connectionHash] = transport
        return transport
    }

    /// Tears down a host's shared SSH master (used when removing a host).
    func disconnectMaster(host: RemoteTmuxHost) async {
        let transport = transports.removeValue(forKey: host.connectionHash)
        await transport?.shutdownMaster()
    }

    /// Whether a transport already exists for `connectionHash` (the reattach-reclaim check).
    func contains(connectionHash: String) -> Bool {
        transports[connectionHash] != nil
    }

    /// Removes and returns the transport for `connectionHash`, if any.
    @discardableResult
    func remove(connectionHash: String) -> RemoteTmuxSSHTransport? {
        transports.removeValue(forKey: connectionHash)
    }

    /// The hosts of every currently-tracked transport.
    func allHosts() -> [RemoteTmuxHost] {
        transports.values.map(\.host)
    }

    /// Drops every tracked transport (does not exit their masters).
    func removeAll() {
        transports.removeAll()
    }
}
