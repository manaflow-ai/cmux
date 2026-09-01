import CmuxSettings
import CmuxFoundation
import Darwin
import Foundation

/// A bounded, cancellable compatibility waiter for clients that predate the
/// canonical `server ensure` command. The current client performs readiness
/// and detached-owner bookkeeping itself. This timer exists only for an old
/// foreground `server start` artifact, and its single completion gate prevents
/// a timeout, process exit, and task cancellation from racing a continuation.
private final class TuiDaemonSocketReadinessWaiter: @unchecked Sendable {
    private let process: Process
    private let socketPath: String
    private let deadline: UInt64
    private let probe: @Sendable (String) -> Bool
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var completedResult: Bool?
    private var completed = false
    private let timer: DispatchSourceTimer

    init(
        process: Process,
        socketPath: String,
        timeout: Duration,
        probe: @escaping @Sendable (String) -> Bool
    ) {
        self.process = process
        self.socketPath = socketPath
        let components = timeout.components
        let seconds = max(Int64(0), components.seconds)
        let fractionalNanoseconds = max(Int64(0), components.attoseconds / 1_000_000_000)
        let nanoseconds = max(
            UInt64(1),
            UInt64(seconds) * 1_000_000_000 + UInt64(fractionalNanoseconds)
        )
        self.deadline = DispatchTime.now().uptimeNanoseconds + nanoseconds
        self.probe = probe
        self.timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    }

    func start() {
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(50),
            leeway: .milliseconds(10)
        )
        timer.resume()
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let completedResult {
                lock.unlock()
                continuation.resume(returning: completedResult)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func cancel() {
        complete(false)
    }

    private func poll() {
        if probe(socketPath) {
            complete(true)
        } else if !process.isRunning || DispatchTime.now().uptimeNanoseconds >= deadline {
            complete(false)
        }
    }

    private func complete(_ result: Bool) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        completedResult = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        timer.cancel()
        if !result, process.isRunning {
            process.terminate()
        }
        continuation?.resume(returning: result)
    }
}

/// I/O side of the cmux-tui terminal backend: ensures the per-app-tag
/// daemon session is running, provisions daemon terminals for new surfaces,
/// and answers reattach queries during session restore. Decision logic lives
/// in `TuiTerminalAttachPolicy`.
@MainActor
final class TuiTerminalAttachBridge {
    static let shared = TuiTerminalAttachBridge()

    struct ProvisionedTerminal: Equatable {
        enum State: Equatable {
            case pending
            case ready(terminalID: String, attachCommand: String)
        }

        let state: State

        var isPending: Bool {
            if case .pending = state { return true }
            return false
        }

        var terminalID: String? {
            guard case let .ready(terminalID, _) = state else { return nil }
            return terminalID
        }

        var attachCommand: String? {
            guard case let .ready(_, attachCommand) = state else { return nil }
            return attachCommand
        }

        static let pending = ProvisionedTerminal(state: .pending)

        /// Constructs a ready lease only from a non-empty identity and
        /// command. A malformed daemon response cannot become a fake pending
        /// terminal or an empty shell command.
        init?(terminalID: String, attachCommand: String) {
            let normalizedID = terminalID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty, !attachCommand.isEmpty else { return nil }
            state = .ready(terminalID: normalizedID, attachCommand: attachCommand)
        }

        private init(state: State) {
            self.state = state
        }
    }

    /// Synchronous read of the beta flag for spawn/restore paths outside the
    /// SwiftUI update cycle, mirroring `RemoteTmuxController.isEnabled`.
    nonisolated static var isEnabled: Bool {
        let key = SettingCatalog().betaFeatures.tuiTerminalBackend
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey))
            ?? key.defaultValue
    }

    /// Manual-IO data-path variant: the daemon terminal feeds a
    /// manual-mirror Ghostty surface through a `--pipe-io` relay instead of
    /// running the attach client as the surface command. Requires the main
    /// backend flag.
    nonisolated static var isManualIOEnabled: Bool {
        guard isEnabled else { return false }
        let key = SettingCatalog().betaFeatures.tuiTerminalBackendManualIO
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey))
            ?? key.defaultValue
    }

    /// A pump owning the `--pipe-io` relay for one daemon terminal, sharing
    /// this bridge's binary, per-app-tag session, and config isolation.
    func makeManualIOPump(terminalID: String? = nil) -> TuiManualIOPump {
        TuiManualIOPump(
            binaryPath: Self.binaryPath,
            sessionName: sessionName,
            terminalID: terminalID,
            environment: Self.bridgeEnvironment
        )
    }

    private nonisolated static var binaryPath: String {
        let key = SettingCatalog().betaFeatures.tuiTerminalBackendBinaryPath
        let stored = String.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey))
        return resolveBinaryPath(
            storedOverride: stored,
            bundle: .main,
            environment: ProcessInfo.processInfo.environment
        ) ?? ""
    }

    /// Resolve the client in one place for provisioning, capability probing,
    /// and Harbor discovery. An explicit Settings value is authoritative. An
    /// empty setting means "use the app artifact", never "search PATH": a
    /// GUI launched from Finder does not have a stable interactive PATH and a
    /// PATH search can silently select a client from another release.
    ///
    /// The environment override is the documented development escape hatch
    /// used by tagged builds and tests. It is delegated to the same resolver
    /// as the cloud client so the binary used for Harbor and cloud links cannot
    /// diverge.
    nonisolated static func resolveBinaryPath(
        storedOverride: String?,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let storedOverride {
            let trimmed = storedOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return FileManager.default.isExecutableFile(atPath: trimmed) ? trimmed : nil
            }
        }
        return CloudTuiClientPaths.clientURL(bundle: bundle, environment: environment)?.path
    }

    /// The selected binary used by Harbor's local discovery probe. Keep this
    /// read-only accessor separate from the bridge's process-launch details so
    /// discovery can use the same configured executable without duplicating
    /// settings decoding.
    nonisolated static var configuredBinaryPath: String { binaryPath }

    private var cachedTerminalIDs: (ids: Set<String>, fetchedAt: Date)?
    private var cachedCloseConfirmations: [String: (required: Bool, fetchedAt: Date)] = [:]
    private var capabilityProbeTask: Task<Bool, Never>?
    private var terminalInventoryTask: Task<Void, Never>?
    private var daemonStartTask: Task<Bool, Never>?
    private var closeConfirmationTasks: Set<String> = []
    /// The app bundles a rolling cmux-tui artifact. Cache the capability by
    /// path and modification date so one old artifact cannot crash-loop every
    /// manual-mirror pane, while an installed replacement is detected.
    private var cachedPipeIOCapability: (path: String, modificationDate: Date?, supported: Bool)?

    /// App-managed config for every bridge-spawned cmux-tui process (daemon,
    /// CLI calls, attach clients). Isolates app sessions from the user's
    /// interactive `~/.config/cmux/cmux-tui.json`, whose schema may belong to
    /// a different binary version; parse warnings from that file print onto
    /// the surface and flash when the alt screen pops on quit.
    nonisolated static let bridgeConfigPath: String = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("cmux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("tui-bridge.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? Data("{}\n".utf8).write(to: file)
        }
        return file.path
    }()

    /// Environment for every bridge-spawned cmux-tui process (the daemon and
    /// each CLI call). The app keeps normal launch context such as PATH, HOME,
    /// locale, and credentials, but removes ambient cmux-tui session
    /// capabilities. Every bridge operation carries its socket/session and
    /// terminal identity explicitly in argv. Inheriting these variables would
    /// let a stale parent terminal silently redirect a command to the wrong
    /// daemon or terminal.
    nonisolated static var bridgeEnvironment: [String: String] {
        sanitizedBridgeEnvironment(
            base: ProcessInfo.processInfo.environment,
            configPath: bridgeConfigPath
        )
    }

    /// Pure environment boundary used by the process launchers and tests.
    /// These names are the cmux-tui protocol's ambient session capabilities,
    /// including the legacy socket alias and hook context. They belong only
    /// to a daemon-created child surface, never to a bridge client.
    nonisolated static func sanitizedBridgeEnvironment(
        base: [String: String],
        configPath: String
    ) -> [String: String] {
        var env = base
        for key in [
            "CMUX_TUI_SOCKET",
            "CMUX_MUX_SOCKET",
            "CMUX_TUI_TERMINAL_ID",
            "CMUX_TUI_SESSION_ID",
            "CMUX_TUI_HOOK",
            "CMUX_SIDEBAR",
        ] {
            env.removeValue(forKey: key)
        }
        // The bridge config is an explicit authority. A non-empty value is
        // required because cmux-tui treats an empty value as "use the user's
        // config".
        env["CMUX_TUI_CONFIG"] = configPath
        // A daemon has no terminal parent from which to inherit TERM. Set the
        // child-shell term at the process boundary for every bridge command,
        // including `server ensure` and old-client fallback starts. This
        // keeps the daemon's PTY geometry and Ghostty's terminfo contract
        // aligned instead of relying on whatever environment launched cmux.
        env["CMUX_TUI_TERM"] = TuiTerminalAttachPolicy.childShellTerm
        return env
    }

    /// True when the enabled beta path has a cached renderer-less relay
    /// capability. A cache miss schedules a probe and returns false. New
    /// surfaces do not use this speculative value for their ownership choice;
    /// their pending provisioning transaction awaits the same probe.
    func isManualIOAvailable() -> Bool {
        guard Self.isManualIOEnabled else { return false }
        let binary = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            logBridge("manualIO.capability unsupported reason=binary-not-executable path=\(binary)")
            return false
        }
        let modificationDate = (try? FileManager.default.attributesOfItem(atPath: binary))?[.modificationDate] as? Date
        if let cachedPipeIOCapability,
           cachedPipeIOCapability.path == binary,
           cachedPipeIOCapability.modificationDate == modificationDate {
            return cachedPipeIOCapability.supported
        }
        scheduleCapabilityProbe(binary: binary, modificationDate: modificationDate)
        return false
    }

    /// The cached capability state. A cache miss schedules the same probe as
    /// ``isManualIOAvailable()`` and returns `.unknown`. New surfaces may
    /// mount a pending manual lease, while the provisioning transaction waits
    /// for the result before creating a daemon terminal.
    enum ManualIOCapability: Equatable {
        case unknown
        case supported
        case unsupported
    }

    func manualIOCapability() -> ManualIOCapability {
        guard Self.isManualIOEnabled else { return .unsupported }
        let binary = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: binary) else { return .unsupported }
        let modificationDate = (try? FileManager.default.attributesOfItem(atPath: binary))?[.modificationDate] as? Date
        guard let cachedPipeIOCapability,
              cachedPipeIOCapability.path == binary,
              cachedPipeIOCapability.modificationDate == modificationDate else {
            scheduleCapabilityProbe(binary: binary, modificationDate: modificationDate)
            return .unknown
        }
        return cachedPipeIOCapability.supported ? .supported : .unsupported
    }

    /// Starts the capability probe without making a terminal decision. The
    /// app calls this during launch so the first user-created terminal does
    /// not pay the capability discovery race.
    func warmManualIOCapabilityProbe() {
        _ = manualIOCapability()
    }

    private func scheduleCapabilityProbe(binary: String, modificationDate: Date?) {
        guard capabilityProbeTask == nil else { return }
        capabilityProbeTask = Task { @MainActor [weak self] in
            let output = await Self.runCLIAsync(
                binary: binary,
                arguments: ["attach", "--help"],
                timeout: 10
            )
            let supported = TuiTerminalAttachPolicy.supportsPipeIO(fromHelpOutput: output)
            guard let self else { return supported }
            // A Settings change or an installed client can invalidate this
            // result while the process is running. Never publish a probe for
            // a different executable generation.
            guard Self.binaryPath == binary else {
                self.capabilityProbeTask = nil
                return supported
            }
            self.cachedPipeIOCapability = (binary, modificationDate, supported)
            self.capabilityProbeTask = nil
            self.logBridge("manualIO.capability path=\(binary) supported=\(supported ? 1 : 0)")
            return supported
        }
    }

    /// Resolves the selected client's pipe-IO capability as part of the
    /// provisioning transaction. Every concurrent creator awaits one probe,
    /// so a cache miss cannot silently change the IO owner of a new surface.
    private func ensureManualIOCapabilityAsync(binary: String) async -> Bool {
        guard Self.isManualIOEnabled,
              FileManager.default.isExecutableFile(atPath: binary) else {
            return false
        }
        let modificationDate = (try? FileManager.default.attributesOfItem(atPath: binary))?[.modificationDate] as? Date
        if let cachedPipeIOCapability,
           cachedPipeIOCapability.path == binary,
           cachedPipeIOCapability.modificationDate == modificationDate {
            return cachedPipeIOCapability.supported
        }
        scheduleCapabilityProbe(binary: binary, modificationDate: modificationDate)
        guard let capabilityProbeTask else { return false }
        return await capabilityProbeTask.value
    }

    private var sessionName: String {
        TuiTerminalAttachPolicy.sessionName(
            controlSocketPath: TerminalController.shared.activeSocketPath(
                preferredPath: SocketControlSettings.socketPath()
            )
        )
    }

    private var daemonSocketPath: String {
        TuiTerminalAttachPolicy.daemonSocketPath(
            sessionName: sessionName,
            temporaryDirectory: NSTemporaryDirectory(),
            uid: getuid()
        )
    }

    /// Asynchronously creates one daemon-backed terminal for a brand-new
    /// surface. The completion runs on the main actor after the CLI transaction
    /// commits. A caller that has already discarded its panel must close the
    /// returned terminal instead of retaining it.
    @discardableResult
    func requestTerminalForNewSurface(
        completion: @escaping @MainActor (ProvisionedTerminal?) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let provisioned = await self.provisionTerminalForNewSurfaceAsync()
            guard !Task.isCancelled else {
                if let terminalID = provisioned?.terminalID {
                    self.closeProvisionedHarborTerminal(terminalID: terminalID)
                }
                return
            }
            completion(provisioned)
        }
    }

    private func provisionTerminalForNewSurfaceAsync() async -> ProvisionedTerminal? {
        let binary = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            logBridge("provision.skip binary-not-executable path=\(binary)")
            return nil
        }
        // Capability is part of the provisioning transaction. Do not create a
        // durable terminal that this app cannot render.
        guard await ensureManualIOCapabilityAsync(binary: binary) else {
            logBridge("provision.skip pipe-io-unsupported path=\(binary)")
            return nil
        }
        let session = sessionName
        guard await ensureDaemonRunningAsync(binary: binary) else { return nil }
        guard let output = await Self.runCLIAsync(
            binary: binary,
            arguments: ["--session", session, "--json", "workspace", "create", "--name", "cmux-gui"],
            timeout: 10
        ) else {
            logBridge("provision.fail workspace-create session=\(session)")
            return nil
        }
        guard let terminalID = TuiTerminalAttachPolicy.terminalID(fromWorkspaceCreateJSON: output) else {
            logBridge("provision.fail parse session=\(session)")
            return nil
        }
        cachedTerminalIDs = nil
        logBridge("provision.ok terminal=\(terminalID) session=\(session)")
        return ProvisionedTerminal(
            terminalID: terminalID,
            attachCommand: TuiTerminalAttachPolicy.attachCommand(
                binaryPath: binary,
                sessionName: session,
                terminalID: terminalID,
                configPath: Self.bridgeConfigPath
            )
        )
    }

    /// The bridge daemon session backing this app instance, for callers that
    /// must recognize (and skip) it during discovery.
    var currentSessionName: String { sessionName }

    /// Harbor: asynchronously creates one daemon terminal running
    /// `shellCommand` through the daemon's default login shell, inside the
    /// shared `harbor` workspace. The completion runs on the main actor.
    @discardableResult
    func requestHarborTerminal(
        shellCommand: String,
        terminalName: String,
        completion: @escaping @MainActor (String?) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let terminalID = await self.provisionHarborTerminalAsync(
                shellCommand: shellCommand,
                terminalName: terminalName
            )
            guard !Task.isCancelled else {
                if let terminalID {
                    self.closeProvisionedHarborTerminal(terminalID: terminalID)
                }
                return
            }
            completion(terminalID)
        }
    }

    private func provisionHarborTerminalAsync(shellCommand: String, terminalName: String) async -> String? {
        guard Self.isManualIOEnabled else {
            logBridge("harbor.provision.skip manual-io-disabled")
            return nil
        }
        let binary = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            logBridge("harbor.provision.skip binary-not-executable path=\(binary)")
            return nil
        }
        let session = sessionName
        guard await ensureDaemonRunningAsync(binary: binary) else { return nil }

        func run(inWorkspace selector: String) async -> String? {
            guard let output = await Self.runCLIAsync(
                binary: binary,
                arguments: TuiTerminalAttachPolicy.harborRunArguments(
                    sessionName: session,
                    workspaceSelector: selector,
                    terminalName: terminalName,
                    shellCommand: shellCommand
                ),
                timeout: 10
            ) else { return nil }
            return TuiTerminalAttachPolicy.terminalID(fromWorkspaceCreateJSON: output)
        }

        // Reuse the shared harbor workspace when it already exists; create it
        // only when the name selector fails to resolve.
        if let terminalID = await run(inWorkspace: TuiTerminalAttachPolicy.harborWorkspaceName) {
            cachedTerminalIDs = nil
            logBridge("harbor.provision.ok terminal=\(terminalID) session=\(session)")
            return terminalID
        }
        guard let createOutput = await Self.runCLIAsync(
            binary: binary,
            arguments: TuiTerminalAttachPolicy.harborWorkspaceCreateArguments(sessionName: session),
            timeout: 10
        ), let workspaceID = TuiTerminalAttachPolicy.workspaceID(fromWorkspaceCreateJSON: createOutput) else {
            logBridge("harbor.provision.fail workspace-create session=\(session)")
            return nil
        }
        guard let terminalID = await run(inWorkspace: workspaceID) else {
            logBridge("harbor.provision.fail run session=\(session)")
            return nil
        }
        cachedTerminalIDs = nil
        logBridge("harbor.provision.ok terminal=\(terminalID) session=\(session)")
        return terminalID
    }

    /// Restore-side decision: reattach to a persisted daemon terminal, or
    /// fall back to a fresh spawn. Never starts the daemon: if it is not
    /// already running, the terminal it owned is gone anyway.
    func restoreDecision(
        snapshotTerminalID: String?,
        isRemoteTerminal: Bool,
        hasRemotePTYSessionID: Bool
    ) -> TuiTerminalAttachPolicy.RestoreDecision {
        guard Self.isEnabled, let snapshotTerminalID, !snapshotTerminalID.isEmpty else {
            return .freshSpawn
        }
        let daemonSocketAlive = Self.unixSocketAccepts(path: daemonSocketPath)
        let daemonTerminalIDs: Set<String>?
        if daemonSocketAlive {
            daemonTerminalIDs = cachedLiveTerminalIDs()
            if daemonTerminalIDs == nil {
                scheduleTerminalInventoryRefresh()
            }
        } else {
            daemonTerminalIDs = nil
        }
        let decision = TuiTerminalAttachPolicy.restoreDecision(
            flagEnabled: Self.isEnabled,
            snapshotTerminalID: snapshotTerminalID,
            isRemoteTerminal: isRemoteTerminal,
            hasRemotePTYSessionID: hasRemotePTYSessionID,
            daemonSocketAlive: daemonSocketAlive,
            daemonTerminalIDs: daemonTerminalIDs
        )
        logBridge("restore.decision terminal=\(snapshotTerminalID) alive=\(daemonSocketAlive) decision=\(decision)")
        return decision
    }

    /// Quit-time inventory: whether the daemon session for this app instance
    /// should be offered the keep-vs-stop choice. The socket check is local and
    /// nonblocking. If the live-terminal inventory is not warm yet, prompt
    /// conservatively and refresh it asynchronously so a live session is never
    /// silently abandoned.
    func shouldPromptToKeepDaemonSessionsOnQuit(quitAlreadyConfirmed: Bool) -> Bool {
        guard Self.isEnabled, !quitAlreadyConfirmed else { return false }
        let daemonSocketAlive = Self.unixSocketAccepts(path: daemonSocketPath)
        guard daemonSocketAlive else { return false }
        guard let terminalIDs = cachedLiveTerminalIDs() else {
            scheduleTerminalInventoryRefresh()
            return true
        }
        return TuiTerminalAttachPolicy.shouldPromptToKeepDaemonSessionsOnQuit(
            flagEnabled: Self.isEnabled,
            quitAlreadyConfirmed: quitAlreadyConfirmed,
            daemonSocketAlive: daemonSocketAlive,
            liveTerminalIDs: terminalIDs
        )
    }

    /// Truly stops the daemon session for quit: closes every live terminal
    /// (ending the session-owned shell processes), then stops the server.
    /// Runs off the main actor; each CLI call is individually bounded, so a
    /// wedged daemon cannot hang quit indefinitely.
    func stopDaemonSessionForQuit() async {
        let binary = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: binary) else { return }
        let session = sessionName
        let terminalIDs = (await Self.liveTerminalIDsAsync(binary: binary, sessionName: session) ?? []).sorted()
        cachedTerminalIDs = nil
        let commands = TuiTerminalAttachPolicy.sessionStopCommands(
            sessionName: session,
            terminalIDs: terminalIDs
        )
        logBridge("quitStop.begin session=\(session) terminals=\(terminalIDs.count)")
        for arguments in commands {
            _ = await Self.runCLIAsync(binary: binary, arguments: arguments, timeout: 10)
        }
        logBridge("quitStop.done session=\(session)")
    }

    /// Whether closing the tab backed by `terminalID` must ask first,
    /// consulting the DAEMON terminal's real process state (the local surface
    /// child is the always-running attach client, so the app's process-based
    /// heuristic would prompt for an idle shell). Returns nil when the daemon
    /// cannot be queried so the caller falls back to the existing prompt
    /// behavior instead of silently skipping confirmation. A cache miss starts
    /// one asynchronous query and returns nil, which preserves the existing
    /// conservative prompt behavior while keeping close handling responsive.
    func closeConfirmationRequired(terminalID: String) -> Bool? {
        guard Self.isEnabled else { return nil }
        if let cached = cachedCloseConfirmations[terminalID],
           Date().timeIntervalSince(cached.fetchedAt) < 2 {
            return cached.required
        }
        let binary = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: binary),
              Self.unixSocketAccepts(path: daemonSocketPath) else {
            logBridge("closeConfirm.unavailable terminal=\(terminalID)")
            return nil
        }
        guard closeConfirmationTasks.insert(terminalID).inserted else { return nil }
        let session = sessionName
        Task { [weak self] in
            let output = await Self.runCLIAsync(
                binary: binary,
                arguments: TuiTerminalAttachPolicy.processShowArguments(
                    sessionName: session,
                    terminalID: terminalID
                ),
                timeout: 5
            )
            guard let self else { return }
            self.closeConfirmationTasks.remove(terminalID)
            switch TuiTerminalAttachPolicy.closeConfirmationDecision(fromProcessShowJSON: output) {
            case .prompt:
                self.cachedCloseConfirmations[terminalID] = (true, Date())
                self.logBridge("closeConfirm.decision terminal=\(terminalID) required=1")
            case .noPrompt:
                self.cachedCloseConfirmations[terminalID] = (false, Date())
                self.logBridge("closeConfirm.decision terminal=\(terminalID) required=0")
            case .unknown:
                self.logBridge("closeConfirm.decision terminal=\(terminalID) required=unknown")
            }
        }
        return nil
    }

    /// Closes one daemon terminal after its GUI tab (or pane/workspace) was
    /// closed, so the close cannot orphan a live daemon terminal.
    /// Fire-and-forget off the main actor: a failure leaves the terminal
    /// adoptable (today's pre-fix behavior) and is only logged.
    func closeTerminalForClosedSurface(terminalID: String) {
        let binary = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: binary) else { return }
        cachedTerminalIDs = nil
        cachedCloseConfirmations.removeValue(forKey: terminalID)
        let arguments = TuiTerminalAttachPolicy.terminalCloseArguments(
            sessionName: sessionName,
            terminalID: terminalID
        )
        logBridge("surfaceClose.begin terminal=\(terminalID)")
        Task { [terminalID] in
            let output = await Self.runCLIAsync(binary: binary, arguments: arguments, timeout: 10)
            Self.logBridgeStatic("surfaceClose.done terminal=\(terminalID) ok=\(output != nil ? 1 : 0)")
        }
    }

    /// Rolls back a Harbor terminal when pane creation fails after the daemon
    /// already created it. Without this cleanup, a rejected drop leaves an
    /// unreachable terminal in the daemon's durable catalog.
    func closeProvisionedHarborTerminal(terminalID: String) {
        closeTerminalForClosedSurface(terminalID: terminalID)
    }

    /// The attach command for a terminal id this bridge (or a previous app
    /// run) provisioned.
    func attachCommand(terminalID: String) -> String {
        TuiTerminalAttachPolicy.attachCommand(
            binaryPath: Self.binaryPath,
            sessionName: sessionName,
            terminalID: terminalID,
            configPath: Self.bridgeConfigPath
        )
    }

    // MARK: - Daemon lifecycle

    /// Coalesces cold starts so two simultaneous surface requests cannot start
    /// two daemons for the same app session.
    private func ensureDaemonRunningAsync(binary: String) async -> Bool {
        let socketPath = daemonSocketPath
        if Self.unixSocketAccepts(path: socketPath) { return true }
        if let daemonStartTask {
            return await daemonStartTask.value
        }
        let session = sessionName
        let task = Task.detached(priority: .userInitiated) {
            await Self.startDaemonAndWaitForSocket(
                binary: binary,
                session: session,
                socketPath: socketPath
            )
        }
        daemonStartTask = task
        let result = await task.value
        if daemonStartTask != nil {
            daemonStartTask = nil
        }
        return result
    }

    /// Launches the daemon and waits for its socket without blocking a Swift
    /// actor. The socket probe is a readiness check, not a synchronization
    /// sleep. The canonical `server ensure` branch delegates cancellation and
    /// ownership to cmux-tui. The legacy branch is a bounded foreground
    /// compatibility process and is terminated when its readiness transaction
    /// is cancelled or fails.
    private nonisolated static func startDaemonAndWaitForSocket(
        binary: String,
        session: String,
        socketPath: String
    ) async -> Bool {
        if unixSocketAccepts(path: socketPath) { return true }
        // `server ensure` is the authoritative lifecycle transaction. It
        // starts a detached owner under the client's socket lock, validates
        // the owner identity, and waits for readiness itself. The app must
        // not duplicate that protocol with a best-effort spawn when the
        // selected artifact supports it.
        let ensureResult = await runCLIResultAsync(
            binary: binary,
            arguments: TuiTerminalAttachPolicy.daemonEnsureArguments(
                sessionName: session,
                socketPath: socketPath
            ),
            timeout: 12
        )
        switch TuiTerminalAttachPolicy.classifyDaemonEnsureResult(
            exitStatus: ensureResult.exitStatus,
            timedOut: ensureResult.timedOut,
            executionError: ensureResult.executionError,
            stdout: ensureResult.stdout,
            stderr: ensureResult.stderr,
            expectedSession: session,
            expectedSocket: socketPath
        ) {
        case .ready:
            return true
        case .failed:
            logBridgeStatic("daemon.ensure.fail session=\(session) status=\(ensureResult.exitStatus.map(String.init) ?? "nil")")
            return false
        case .unsupported:
            // Continue only for a known old client. This branch is a bounded
            // compatibility path, not an alternative lifecycle protocol for
            // current artifacts.
            logBridgeStatic("daemon.ensure.unsupported session=\(session)")
        }

        logBridgeStatic("daemon.start session=\(session)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = TuiTerminalAttachPolicy.daemonStartArguments(
            sessionName: session,
            socketPath: socketPath
        )
        process.environment = bridgeEnvironment
        let logPath = "/tmp/cmux-tui-\(session).log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        if let logHandle = FileHandle(forWritingAtPath: logPath) {
            logHandle.seekToEndOfFile()
            process.standardOutput = logHandle
            process.standardError = logHandle
        }
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logBridgeStatic("daemon.start.fail error=\(error)")
            return false
        }
        let waiter = TuiDaemonSocketReadinessWaiter(
            process: process,
            socketPath: socketPath,
            timeout: .seconds(5),
            probe: { path in Self.unixSocketAccepts(path: path) }
        )
        waiter.start()
        let ready = await withTaskCancellationHandler {
            await waiter.wait()
        } onCancel: {
            waiter.cancel()
        }
        if ready {
            return true
        }
        if process.isRunning {
            logBridgeStatic("daemon.start.not-ready session=\(session)")
        } else {
            logBridgeStatic("daemon.start.exited status=\(process.terminationStatus)")
        }
        return false
    }

    private func cachedLiveTerminalIDs() -> Set<String>? {
        guard let cached = cachedTerminalIDs,
              Date().timeIntervalSince(cached.fetchedAt) < 3 else {
            return nil
        }
        return cached.ids
    }

    private func scheduleTerminalInventoryRefresh() {
        guard terminalInventoryTask == nil else { return }
        let binary = Self.binaryPath
        let session = sessionName
        terminalInventoryTask = Task { [weak self] in
            let ids = await Self.liveTerminalIDsAsync(binary: binary, sessionName: session)
            guard let self else { return }
            self.terminalInventoryTask = nil
            if let ids {
                self.cachedTerminalIDs = (ids, Date())
            }
        }
    }

    private nonisolated static func liveTerminalIDsAsync(
        binary: String,
        sessionName: String
    ) async -> Set<String>? {
        guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }
        guard let output = await runCLIAsync(
            binary: binary,
            arguments: ["--session", sessionName, "--json", "terminal", "list"],
            timeout: 10
        ) else { return nil }
        return TuiTerminalAttachPolicy.terminalIDs(fromTerminalListJSON: output)
    }

    // MARK: - Helpers

    /// Runs one short cmux-tui CLI call without blocking the caller's actor.
    /// `CommandRunner` drains both streams, enforces cancellation and timeout,
    /// and closes every descriptor before returning.
    private nonisolated static func runCLIAsync(
        binary: String,
        arguments: [String],
        timeout: TimeInterval
    ) async -> Data? {
        let result = await runCLIResultAsync(binary: binary, arguments: arguments, timeout: timeout)
        guard result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0,
              let stdout = result.stdout else {
            return nil
        }
        return Data(stdout.utf8)
    }

    /// Runs one short cmux-tui command and retains its complete outcome for
    /// protocol classification. Keeping this beside ``runCLIAsync`` prevents
    /// lifecycle callers from inferring support from a nil stdout alone.
    private nonisolated static func runCLIResultAsync(
        binary: String,
        arguments: [String],
        timeout: TimeInterval
    ) async -> CommandResult {
        await CommandRunner().run(
            directory: NSTemporaryDirectory(),
            executable: binary,
            arguments: arguments,
            timeout: timeout,
            environmentOverrides: bridgeEnvironment
        )
    }

    /// True when a Unix socket at `path` accepts a connection.
    private nonisolated static func unixSocketAccepts(path: String) -> Bool {
        guard path.utf8.count < 104 else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let copied = withUnsafeMutableBytes(of: &address.sun_path) { buffer -> Bool in
            let bytes = Array(path.utf8)
            guard bytes.count < buffer.count else { return false }
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
            buffer[bytes.count] = 0
            return true
        }
        guard copied else { return false }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(fd, rebound, length)
            }
        }
        return result == 0
    }

    private nonisolated func logBridge(_ message: @autoclosure () -> String) {
#if DEBUG
        cmuxDebugLog("tuiAttachBridge.\(message())")
#endif
    }

    private nonisolated static func logBridgeStatic(_ message: @autoclosure () -> String) {
#if DEBUG
        cmuxDebugLog("tuiAttachBridge.\(message())")
#endif
    }
}
