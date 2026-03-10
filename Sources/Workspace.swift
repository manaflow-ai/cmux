import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import Darwin
import Network
import CoreText

func cmuxSurfaceContextName(_ context: ghostty_surface_context_e) -> String {
    switch context {
    case GHOSTTY_SURFACE_CONTEXT_WINDOW:
        return "window"
    case GHOSTTY_SURFACE_CONTEXT_TAB:
        return "tab"
    case GHOSTTY_SURFACE_CONTEXT_SPLIT:
        return "split"
    default:
        return "unknown(\(context))"
    }
}

func cmuxCurrentSurfaceFontSizePoints(_ surface: ghostty_surface_t) -> Float? {
    guard let quicklookFont = ghostty_surface_quicklook_font(surface) else {
        return nil
    }

    let ctFont = Unmanaged<CTFont>.fromOpaque(quicklookFont).takeRetainedValue()
    let points = Float(CTFontGetSize(ctFont))
    guard points > 0 else { return nil }
    return points
}

func cmuxInheritedSurfaceConfig(
    sourceSurface: ghostty_surface_t,
    context: ghostty_surface_context_e
) -> ghostty_surface_config_s {
    let inherited = ghostty_surface_inherited_config(sourceSurface, context)
    var config = inherited

    // Make runtime zoom inheritance explicit, even when Ghostty's
    // inherit-font-size config is disabled.
    let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface)
    if let points = runtimePoints {
        config.font_size = points
    }

#if DEBUG
    let inheritedText = String(format: "%.2f", inherited.font_size)
    let runtimeText = runtimePoints.map { String(format: "%.2f", $0) } ?? "nil"
    let finalText = String(format: "%.2f", config.font_size)
    dlog(
        "zoom.inherit context=\(cmuxSurfaceContextName(context)) " +
        "inherited=\(inheritedText) runtime=\(runtimeText) final=\(finalText)"
    )
#endif

    return config
}

struct SidebarStatusEntry {
    let key: String
    let value: String
    let icon: String?
    let color: String?
    let url: URL?
    let priority: Int
    let format: SidebarMetadataFormat
    let timestamp: Date

    init(
        key: String,
        value: String,
        icon: String? = nil,
        color: String? = nil,
        url: URL? = nil,
        priority: Int = 0,
        format: SidebarMetadataFormat = .plain,
        timestamp: Date = Date()
    ) {
        self.key = key
        self.value = value
        self.icon = icon
        self.color = color
        self.url = url
        self.priority = priority
        self.format = format
        self.timestamp = timestamp
    }
}

struct SidebarMetadataBlock {
    let key: String
    let markdown: String
    let priority: Int
    let timestamp: Date
}

enum SidebarMetadataFormat: String {
    case plain
    case markdown
}

private struct SessionPaneRestoreEntry {
    let paneId: PaneID
    let snapshot: SessionPaneLayoutSnapshot
}

private final class WorkspaceRemoteSessionController {
    private struct ForwardEntry {
        let process: Process
        let stderrPipe: Pipe
    }

    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private struct RemotePlatform {
        let goOS: String
        let goArch: String
    }

    private struct DaemonHello {
        let name: String
        let version: String
        let capabilities: [String]
        let remotePath: String
    }

    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.\(UUID().uuidString)", qos: .utility)
    private weak var workspace: Workspace?
    private let configuration: WorkspaceRemoteConfiguration

    private var isStopping = false
    private var probeProcess: Process?
    private var probeStdoutPipe: Pipe?
    private var probeStderrPipe: Pipe?
    private var probeStdoutBuffer = ""
    private var probeStderrBuffer = ""

    private var desiredRemotePorts: Set<Int> = []
    private var forwardEntries: [Int: ForwardEntry] = [:]
    private var portConflicts: Set<Int> = []
    private var daemonReady = false
    private var daemonBootstrapVersion: String?
    private var daemonRemotePath: String?
    private var reconnectRetryCount = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var reverseRelayProcess: Process?
    private var reverseRelayStderrPipe: Pipe?

    init(workspace: Workspace, configuration: WorkspaceRemoteConfiguration) {
        self.workspace = workspace
        self.configuration = configuration
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isStopping else { return }
            self.beginConnectionAttemptLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopAllLocked()
        }
    }

    private func stopAllLocked() {
        isStopping = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectRetryCount = 0

        if let probeProcess {
            probeStdoutPipe?.fileHandleForReading.readabilityHandler = nil
            probeStderrPipe?.fileHandleForReading.readabilityHandler = nil
            if probeProcess.isRunning {
                probeProcess.terminate()
            }
        }
        probeProcess = nil
        probeStdoutPipe = nil
        probeStderrPipe = nil
        probeStdoutBuffer = ""
        probeStderrBuffer = ""

        if let reverseRelayProcess {
            reverseRelayStderrPipe?.fileHandleForReading.readabilityHandler = nil
            if reverseRelayProcess.isRunning {
                reverseRelayProcess.terminate()
            }
        }
        reverseRelayProcess = nil
        reverseRelayStderrPipe = nil

        for (_, entry) in forwardEntries {
            entry.stderrPipe.fileHandleForReading.readabilityHandler = nil
            if entry.process.isRunning {
                entry.process.terminate()
            }
        }
        forwardEntries.removeAll()
        desiredRemotePorts.removeAll()
        portConflicts.removeAll()
        daemonReady = false
        daemonBootstrapVersion = nil
        daemonRemotePath = nil
    }

    private func beginConnectionAttemptLocked() {
        guard !isStopping else { return }

        reconnectWorkItem = nil
        let connectDetail: String
        let bootstrapDetail: String
        if reconnectRetryCount > 0 {
            connectDetail = "Reconnecting to \(configuration.displayTarget) (retry \(reconnectRetryCount))"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget) (retry \(reconnectRetryCount))"
        } else {
            connectDetail = "Connecting to \(configuration.displayTarget)"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget)"
        }
        publishState(.connecting, detail: connectDetail)
        publishDaemonStatus(.bootstrapping, detail: bootstrapDetail)

        do {
            let hello = try bootstrapDaemonLocked()
            daemonReady = true
            daemonBootstrapVersion = hello.version
            daemonRemotePath = hello.remotePath
            publishDaemonStatus(
                .ready,
                detail: "Remote daemon ready",
                version: hello.version,
                name: hello.name,
                capabilities: hello.capabilities,
                remotePath: hello.remotePath
            )
            startReverseRelayLocked()
            startProbeLocked()
        } catch {
            daemonReady = false
            daemonBootstrapVersion = nil
            daemonRemotePath = nil
            let nextRetry = scheduleProbeRestartLocked(delay: 4.0)
            let retrySuffix = Self.retrySuffix(retry: nextRetry, delay: 4.0)
            let detail = "Remote daemon bootstrap failed: \(error.localizedDescription)\(retrySuffix)"
            publishDaemonStatus(.error, detail: detail)
            publishState(.error, detail: detail)
        }
    }

    private func startProbeLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }

        probeStdoutBuffer = ""
        probeStderrBuffer = ""

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = probeArguments()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async {
                self?.consumeProbeStdoutData(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async {
                self?.consumeProbeStderrData(data)
            }
        }

        process.terminationHandler = { [weak self] terminated in
            self?.queue.async {
                self?.handleProbeTermination(terminated)
            }
        }

        do {
            try process.run()
            probeProcess = process
            probeStdoutPipe = stdoutPipe
            probeStderrPipe = stderrPipe
        } catch {
            let nextRetry = scheduleProbeRestartLocked(delay: 3.0)
            let retrySuffix = Self.retrySuffix(retry: nextRetry, delay: 3.0)
            publishState(.error, detail: "Failed to start SSH probe: \(error.localizedDescription)\(retrySuffix)")
        }
    }

    private func handleProbeTermination(_ process: Process) {
        probeStdoutPipe?.fileHandleForReading.readabilityHandler = nil
        probeStderrPipe?.fileHandleForReading.readabilityHandler = nil
        probeProcess = nil
        probeStdoutPipe = nil
        probeStderrPipe = nil

        guard !isStopping else { return }

        for (_, entry) in forwardEntries {
            entry.stderrPipe.fileHandleForReading.readabilityHandler = nil
            if entry.process.isRunning {
                entry.process.terminate()
            }
        }
        forwardEntries.removeAll()
        publishPortsSnapshotLocked()

        let statusCode = process.terminationStatus
        let rawDetail = Self.bestErrorLine(stderr: probeStderrBuffer, stdout: probeStdoutBuffer)
        let detail = rawDetail ?? "SSH probe exited with status \(statusCode)"
        let nextRetry = scheduleProbeRestartLocked(delay: 3.0)
        let retrySuffix = Self.retrySuffix(retry: nextRetry, delay: 3.0)
        publishState(.error, detail: "SSH probe to \(configuration.displayTarget) failed: \(detail)\(retrySuffix)")
    }

    @discardableResult
    private func scheduleProbeRestartLocked(delay: TimeInterval) -> Int {
        guard !isStopping else { return reconnectRetryCount }
        reconnectWorkItem?.cancel()
        reconnectRetryCount += 1
        let retryNumber = reconnectRetryCount
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            guard !self.isStopping else { return }
            guard self.probeProcess == nil else { return }
            self.beginConnectionAttemptLocked()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        return retryNumber
    }

    private func consumeProbeStdoutData(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        probeStdoutBuffer.append(chunk)

        while let newline = probeStdoutBuffer.firstIndex(of: "\n") {
            let line = String(probeStdoutBuffer[..<newline])
            probeStdoutBuffer.removeSubrange(...newline)
            handleProbePortsLine(line)
        }
    }

    private func consumeProbeStderrData(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        probeStderrBuffer.append(chunk)
        if probeStderrBuffer.count > 8192 {
            probeStderrBuffer.removeFirst(probeStderrBuffer.count - 8192)
        }
    }

    private func handleProbePortsLine(_ line: String) {
        guard !isStopping else { return }

        var ports = Set(Self.parseRemotePorts(line: line))
        if let relayPort = configuration.relayPort {
            ports.remove(relayPort)
        }
        // Filter ephemeral ports (49152-65535) — these are SSH reverse relay ports
        // from this or other workspaces, not user services worth forwarding.
        ports = ports.filter { $0 < 49152 }
        desiredRemotePorts = ports
        portConflicts = portConflicts.intersection(desiredRemotePorts)
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectRetryCount = 0
        publishState(.connected, detail: "Connected to \(configuration.displayTarget)")
        reconcileForwardsLocked()
    }

    private func reconcileForwardsLocked() {
        guard !isStopping else { return }

        for (port, entry) in forwardEntries where !desiredRemotePorts.contains(port) {
            entry.stderrPipe.fileHandleForReading.readabilityHandler = nil
            if entry.process.isRunning {
                entry.process.terminate()
            }
            forwardEntries.removeValue(forKey: port)
        }

        for port in desiredRemotePorts.sorted() where forwardEntries[port] == nil {
            guard Self.isLoopbackPortAvailable(port: port) else {
                // Port is already bound locally. If it's reachable (e.g. another
                // workspace is forwarding it), don't flag it as a conflict.
                if Self.isLoopbackPortReachable(port: port) {
                    portConflicts.remove(port)
                } else {
                    portConflicts.insert(port)
                }
                continue
            }
            if startForwardLocked(port: port) {
                portConflicts.remove(port)
            } else {
                portConflicts.insert(port)
            }
        }

        publishPortsSnapshotLocked()
    }

    @discardableResult
    private func startForwardLocked(port: Int) -> Bool {
        guard !isStopping else { return false }

        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = forwardArguments(port: port)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async {
                guard let self else { return }
                if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                    self.probeStderrBuffer.append(chunk)
                    if self.probeStderrBuffer.count > 8192 {
                        self.probeStderrBuffer.removeFirst(self.probeStderrBuffer.count - 8192)
                    }
                }
            }
        }

        process.terminationHandler = { [weak self] terminated in
            self?.queue.async {
                self?.handleForwardTermination(port: port, process: terminated)
            }
        }

        do {
            try process.run()
            forwardEntries[port] = ForwardEntry(process: process, stderrPipe: stderrPipe)
            return true
        } catch {
            publishState(.error, detail: "Failed to forward local :\(port) to \(configuration.displayTarget): \(error.localizedDescription)")
            return false
        }
    }

    private func handleForwardTermination(port: Int, process: Process) {
        if let current = forwardEntries[port], current.process === process {
            current.stderrPipe.fileHandleForReading.readabilityHandler = nil
            forwardEntries.removeValue(forKey: port)
        }

        guard !isStopping else { return }
        publishPortsSnapshotLocked()

        guard desiredRemotePorts.contains(port) else { return }
        let rawDetail = Self.bestErrorLine(stderr: probeStderrBuffer)
        if process.terminationReason != .exit || process.terminationStatus != 0 {
            let detail = rawDetail ?? "process exited with status \(process.terminationStatus)"
            publishState(.error, detail: "SSH port-forward :\(port) dropped for \(configuration.displayTarget): \(detail)")
        }
        guard Self.isLoopbackPortAvailable(port: port) else {
            portConflicts.insert(port)
            publishPortsSnapshotLocked()
            return
        }

        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            guard !self.isStopping else { return }
            guard self.desiredRemotePorts.contains(port) else { return }
            guard self.forwardEntries[port] == nil else { return }
            if self.startForwardLocked(port: port) {
                self.portConflicts.remove(port)
            } else {
                self.portConflicts.insert(port)
            }
            self.publishPortsSnapshotLocked()
        }
    }

    /// Spawns a background SSH process that reverse-forwards a remote TCP port to the local cmux Unix socket.
    /// This process is a direct child of the cmux app, so it passes the `isDescendant()` ancestry check.
    @discardableResult
    private func startReverseRelayLocked() -> Bool {
        guard !isStopping else { return false }
        guard let relayPort = configuration.relayPort, relayPort > 0,
              let localSocketPath = configuration.localSocketPath, !localSocketPath.isEmpty else {
            return false
        }

        // Kill any existing relay process managed by this session
        if let existing = reverseRelayProcess {
            reverseRelayStderrPipe?.fileHandleForReading.readabilityHandler = nil
            if existing.isRunning { existing.terminate() }
            reverseRelayProcess = nil
            reverseRelayStderrPipe = nil
        }

        // Kill orphaned relay SSH processes from previous app sessions that reverse-forward
        // to the same socket path (they survive pkill because they're reparented to launchd).
        Self.killOrphanedRelayProcesses(
            relayPort: relayPort,
            socketPath: localSocketPath,
            destination: configuration.destination
        )

        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        // Build arguments: -N (no remote command), -o ControlPath=none (avoid ControlMaster delegation),
        // then common SSH args, then -R reverse forward, then destination.
        // ExitOnForwardFailure=no because user's ~/.ssh/config may have RemoteForward entries
        // that conflict with already-bound ports — we don't want those to kill our relay.
        var args: [String] = ["-N"]
        args += sshCommonArguments(batchMode: true)
        args += ["-R", "127.0.0.1:\(relayPort):\(localSocketPath)"]
        args += [configuration.destination]
        process.arguments = args

        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async {
                guard let self else { return }
                if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                    self.probeStderrBuffer.append(chunk)
                    if self.probeStderrBuffer.count > 8192 {
                        self.probeStderrBuffer.removeFirst(self.probeStderrBuffer.count - 8192)
                    }
                }
            }
        }

        process.terminationHandler = { [weak self] terminated in
            self?.queue.async {
                self?.handleReverseRelayTermination(process: terminated)
            }
        }

        do {
            try process.run()
            reverseRelayProcess = process
            reverseRelayStderrPipe = stderrPipe
            NSLog("[cmux] reverse relay started: -R 127.0.0.1:%d:%@ → %@", relayPort, localSocketPath, configuration.destination)

            // Write socket_addr after a delay to give the SSH -R forward time to establish.
            // The Go CLI retry loop re-reads this file, so it will pick up the port once ready.
            queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, !self.isStopping else { return }
                guard self.reverseRelayProcess?.isRunning == true else { return }
                self.writeRemoteSocketAddrLocked()
                self.writeRemoteRelayDaemonMappingLocked()
            }

            return true
        } catch {
            NSLog("[cmux] failed to start reverse relay: %@", error.localizedDescription)
            return false
        }
    }

    private func handleReverseRelayTermination(process: Process) {
        if reverseRelayProcess === process {
            reverseRelayStderrPipe?.fileHandleForReading.readabilityHandler = nil
            reverseRelayProcess = nil
            reverseRelayStderrPipe = nil
        }

        guard !isStopping else { return }
        guard configuration.relayPort != nil else { return }

        // Auto-restart after 2 seconds if we're still active
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            guard !self.isStopping else { return }
            guard self.reverseRelayProcess == nil else { return }
            self.startReverseRelayLocked()
        }
    }

    private func publishState(_ state: WorkspaceRemoteConnectionState, detail: String?) {
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            workspace.applyRemoteConnectionStateUpdate(
                state,
                detail: detail,
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    private func publishDaemonStatus(
        _ state: WorkspaceRemoteDaemonState,
        detail: String?,
        version: String? = nil,
        name: String? = nil,
        capabilities: [String] = [],
        remotePath: String? = nil
    ) {
        let status = WorkspaceRemoteDaemonStatus(
            state: state,
            detail: detail,
            version: version,
            name: name,
            capabilities: capabilities,
            remotePath: remotePath
        )
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            workspace.applyRemoteDaemonStatusUpdate(
                status,
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    private func publishPortsSnapshotLocked() {
        let detected = desiredRemotePorts.sorted()
        let forwarded = forwardEntries.keys.sorted()
        let conflicts = portConflicts.sorted()
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            workspace.applyRemotePortsSnapshot(
                detected: detected,
                forwarded: forwarded,
                conflicts: conflicts,
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    private func probeArguments() -> [String] {
        let remoteScript = Self.probeScript()
        let remoteCommand = "sh -lc \(Self.shellSingleQuoted(remoteScript))"
        return sshCommonArguments(batchMode: true) + [configuration.destination, remoteCommand]
    }

    private func forwardArguments(port: Int) -> [String] {
        let localBind = "127.0.0.1:\(port):127.0.0.1:\(port)"
        return ["-N"] + sshCommonArguments(batchMode: true) + ["-L", localBind, configuration.destination]
    }

    private func sshCommonArguments(batchMode: Bool) -> [String] {
        var args: [String] = [
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ExitOnForwardFailure=no",
            "-o", "ControlPath=none",
        ]
        if batchMode {
            args += ["-o", "BatchMode=yes"]
        }
        if let port = configuration.port {
            args += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        for option in configuration.sshOptions {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            args += ["-o", trimmed]
        }
        return args
    }

    private func sshExec(arguments: [String], stdin: Data? = nil, timeout: TimeInterval = 15) throws -> CommandResult {
        try runProcess(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            stdin: stdin,
            timeout: timeout
        )
    }

    private func scpExec(arguments: [String], timeout: TimeInterval = 30) throws -> CommandResult {
        try runProcess(
            executable: "/usr/bin/scp",
            arguments: arguments,
            stdin: nil,
            timeout: timeout
        )
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdin: Data?,
        timeout: TimeInterval
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if stdin != nil {
            process.standardInput = Pipe()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            throw NSError(domain: "cmux.remote.process", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)",
            ])
        }

        if let stdin, let pipe = process.standardInput as? Pipe {
            pipe.fileHandleForWriting.write(stdin)
            try? pipe.fileHandleForWriting.close()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw NSError(domain: "cmux.remote.process", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executable).lastPathComponent) timed out after \(Int(timeout))s",
            ])
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func bootstrapDaemonLocked() throws -> DaemonHello {
        let platform = try resolveRemotePlatformLocked()
        let version = Self.remoteDaemonVersion()
        let remotePath = Self.remoteDaemonPath(version: version, goOS: platform.goOS, goArch: platform.goArch)

        if try !remoteDaemonExistsLocked(remotePath: remotePath) {
            let localBinary = try buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
        }

        createRemoteCLISymlinkLocked(daemonRemotePath: remotePath)

        return try helloRemoteDaemonLocked(remotePath: remotePath)
    }

    /// Installs a stable `cmux` wrapper on the remote and updates the default daemon target.
    /// The wrapper resolves daemon path using relay-port metadata, allowing multiple local
    /// cmux versions to coexist on the same remote host without clobbering each other.
    /// Tries `/usr/local/bin` first (already in PATH, no rc changes needed), falls back to
    /// `~/.cmux/bin`. Non-fatal: logs on failure but does not throw.
    private func createRemoteCLISymlinkLocked(daemonRemotePath: String) {
        let script = """
        mkdir -p "$HOME/.cmux/bin" "$HOME/.cmux/relay"
        ln -sf "$HOME/\(daemonRemotePath)" "$HOME/.cmux/bin/cmuxd-remote-current"
        cat > "$HOME/.cmux/bin/cmux" <<'CMUX_REMOTE_WRAPPER'
        #!/bin/sh
        set -eu

        if [ -n "${CMUX_SOCKET_PATH:-}" ]; then
          _cmux_port="${CMUX_SOCKET_PATH##*:}"
          case "$_cmux_port" in
            ''|*[!0-9]*)
              ;;
            *)
              _cmux_map="$HOME/.cmux/relay/${_cmux_port}.daemon_path"
              if [ -r "$_cmux_map" ]; then
                _cmux_daemon="$(cat "$_cmux_map" 2>/dev/null || true)"
                if [ -n "$_cmux_daemon" ] && [ -x "$_cmux_daemon" ]; then
                  exec "$_cmux_daemon" cli "$@"
                fi
              fi
              ;;
          esac
        fi

        if [ -x "$HOME/.cmux/bin/cmuxd-remote-current" ]; then
          exec "$HOME/.cmux/bin/cmuxd-remote-current" cli "$@"
        fi

        echo "cmux: remote daemon not installed; reconnect from local cmux." >&2
        exit 127
        CMUX_REMOTE_WRAPPER
        chmod 755 "$HOME/.cmux/bin/cmux"
        ln -sf "$HOME/.cmux/bin/cmux" /usr/local/bin/cmux 2>/dev/null \
          || sudo -n ln -sf "$HOME/.cmux/bin/cmux" /usr/local/bin/cmux 2>/dev/null \
          || true
        """
        let command = "sh -lc \(Self.shellSingleQuoted(script))"
        do {
            let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 8)
            if result.status != 0 {
                NSLog("[cmux] warning: failed to create remote CLI symlink (exit %d): %@",
                      result.status,
                      Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "unknown error")
            }
        } catch {
            NSLog("[cmux] warning: failed to create remote CLI symlink: %@", error.localizedDescription)
        }
    }

    /// Writes `~/.cmux/socket_addr` on the remote with the relay TCP address.
    /// The Go CLI relay reads this file as a fallback when CMUX_SOCKET_PATH is not set.
    private func writeRemoteSocketAddrLocked() {
        guard let relayPort = configuration.relayPort, relayPort > 0 else { return }
        let addr = "127.0.0.1:\(relayPort)"
        let script = "mkdir -p \"$HOME/.cmux\" && printf '%s' '\(addr)' > \"$HOME/.cmux/socket_addr\""
        let command = "sh -lc \(Self.shellSingleQuoted(script))"
        do {
            let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 8)
            if result.status != 0 {
                NSLog("[cmux] warning: failed to write remote socket_addr (exit %d): %@",
                      result.status,
                      Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "unknown error")
            }
        } catch {
            NSLog("[cmux] warning: failed to write remote socket_addr: %@", error.localizedDescription)
        }
    }

    /// Writes relay-port -> daemon binary mapping used by the remote `cmux` wrapper.
    /// This keeps CLI dispatch stable when multiple local cmux versions target the same host.
    private func writeRemoteRelayDaemonMappingLocked() {
        guard let relayPort = configuration.relayPort, relayPort > 0,
              let daemonRemotePath, !daemonRemotePath.isEmpty else { return }
        let script = """
        mkdir -p "$HOME/.cmux/relay" && \
        printf '%s' "$HOME/\(daemonRemotePath)" > "$HOME/.cmux/relay/\(relayPort).daemon_path"
        """
        let command = "sh -lc \(Self.shellSingleQuoted(script))"
        do {
            let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 8)
            if result.status != 0 {
                NSLog("[cmux] warning: failed to write remote relay daemon mapping (exit %d): %@",
                      result.status,
                      Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "unknown error")
            }
        } catch {
            NSLog("[cmux] warning: failed to write remote relay daemon mapping: %@", error.localizedDescription)
        }
    }

    private func resolveRemotePlatformLocked() throws -> RemotePlatform {
        let script = "uname -s; uname -m"
        let command = "sh -lc \(Self.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 10)
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "failed to query remote platform: \(detail)",
            ])
        }

        let lines = result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else {
            throw NSError(domain: "cmux.remote.daemon", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "remote platform probe returned invalid output",
            ])
        }

        guard let goOS = Self.mapUnameOS(lines[0]),
              let goArch = Self.mapUnameArch(lines[1]) else {
            throw NSError(domain: "cmux.remote.daemon", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "unsupported remote platform \(lines[0])/\(lines[1])",
            ])
        }

        return RemotePlatform(goOS: goOS, goArch: goArch)
    }

    private func remoteDaemonExistsLocked(remotePath: String) throws -> Bool {
        let script = "if [ -x \(Self.shellSingleQuoted(remotePath)) ]; then echo yes; else echo no; fi"
        let command = "sh -lc \(Self.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 8)
        guard result.status == 0 else { return false }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
    }

    private func buildLocalDaemonBinary(goOS: String, goArch: String, version: String) throws -> URL {
        guard let repoRoot = Self.findRepoRoot() else {
            throw NSError(domain: "cmux.remote.daemon", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "cannot locate cmux repo root for daemon build",
            ])
        }
        let daemonRoot = repoRoot.appendingPathComponent("daemon/remote", isDirectory: true)
        let goModPath = daemonRoot.appendingPathComponent("go.mod").path
        guard FileManager.default.fileExists(atPath: goModPath) else {
            throw NSError(domain: "cmux.remote.daemon", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "missing daemon module at \(goModPath)",
            ])
        }
        guard let goBinary = Self.which("go") else {
            throw NSError(domain: "cmux.remote.daemon", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "go is required to build cmuxd-remote",
            ])
        }

        let cacheRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-remote-daemon-build", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let output = cacheRoot.appendingPathComponent("cmuxd-remote", isDirectory: false)

        var env = ProcessInfo.processInfo.environment
        env["GOOS"] = goOS
        env["GOARCH"] = goArch
        env["CGO_ENABLED"] = "0"
        let ldflags = "-s -w -X main.version=\(version)"
        let result = try runProcess(
            executable: goBinary,
            arguments: ["build", "-trimpath", "-ldflags", ldflags, "-o", output.path, "./cmd/cmuxd-remote"],
            environment: env,
            currentDirectory: daemonRoot,
            stdin: nil,
            timeout: 90
        )
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "go build failed with status \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "failed to build cmuxd-remote: \(detail)",
            ])
        }
        guard FileManager.default.isExecutableFile(atPath: output.path) else {
            throw NSError(domain: "cmux.remote.daemon", code: 24, userInfo: [
                NSLocalizedDescriptionKey: "cmuxd-remote build output is not executable",
            ])
        }
        return output
    }

    private func uploadRemoteDaemonBinaryLocked(localBinary: URL, remotePath: String) throws {
        let remoteDirectory = (remotePath as NSString).deletingLastPathComponent
        let remoteTempPath = "\(remotePath).tmp-\(UUID().uuidString.prefix(8))"

        let mkdirScript = "mkdir -p \(Self.shellSingleQuoted(remoteDirectory))"
        let mkdirCommand = "sh -lc \(Self.shellSingleQuoted(mkdirScript))"
        let mkdirResult = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, mkdirCommand], timeout: 12)
        guard mkdirResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: mkdirResult.stderr, stdout: mkdirResult.stdout) ?? "ssh exited \(mkdirResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "failed to create remote daemon directory: \(detail)",
            ])
        }

        var scpArgs: [String] = ["-q", "-o", "StrictHostKeyChecking=accept-new"]
        if let port = configuration.port {
            scpArgs += ["-P", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scpArgs += ["-i", identityFile]
        }
        for option in configuration.sshOptions {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            scpArgs += ["-o", trimmed]
        }
        scpArgs += [localBinary.path, "\(configuration.destination):\(remoteTempPath)"]
        let scpResult = try scpExec(arguments: scpArgs, timeout: 45)
        guard scpResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: scpResult.stderr, stdout: scpResult.stdout) ?? "scp exited \(scpResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "failed to upload cmuxd-remote: \(detail)",
            ])
        }

        let finalizeScript = """
        chmod 755 \(Self.shellSingleQuoted(remoteTempPath)) && \
        mv \(Self.shellSingleQuoted(remoteTempPath)) \(Self.shellSingleQuoted(remotePath))
        """
        let finalizeCommand = "sh -lc \(Self.shellSingleQuoted(finalizeScript))"
        let finalizeResult = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, finalizeCommand], timeout: 12)
        guard finalizeResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: finalizeResult.stderr, stdout: finalizeResult.stdout) ?? "ssh exited \(finalizeResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "failed to install remote daemon binary: \(detail)",
            ])
        }
    }

    private func helloRemoteDaemonLocked(remotePath: String) throws -> DaemonHello {
        let request = #"{"id":1,"method":"hello","params":{}}"#
        let script = "printf '%s\\n' \(Self.shellSingleQuoted(request)) | \(Self.shellSingleQuoted(remotePath)) serve --stdio"
        let command = "sh -lc \(Self.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 12)
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 40, userInfo: [
                NSLocalizedDescriptionKey: "failed to start remote daemon: \(detail)",
            ])
        }

        let responseLine = result.stdout
            .split(separator: "\n")
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
        guard !responseLine.isEmpty,
              let data = responseLine.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw NSError(domain: "cmux.remote.daemon", code: 41, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello returned invalid JSON",
            ])
        }

        if let ok = payload["ok"] as? Bool, !ok {
            let errorMessage: String = {
                if let errorObject = payload["error"] as? [String: Any],
                   let message = errorObject["message"] as? String,
                   !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }
                return "hello call failed"
            }()
            throw NSError(domain: "cmux.remote.daemon", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello failed: \(errorMessage)",
            ])
        }

        let resultObject = payload["result"] as? [String: Any] ?? [:]
        let name = (resultObject["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (resultObject["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let capabilities = (resultObject["capabilities"] as? [String]) ?? []
        return DaemonHello(
            name: (name?.isEmpty == false ? name! : "cmuxd-remote"),
            version: (version?.isEmpty == false ? version! : "dev"),
            capabilities: capabilities,
            remotePath: remotePath
        )
    }

    private static func parseRemotePorts(line: String) -> [Int] {
        let tokens = line.split(whereSeparator: \.isWhitespace)
        let values = tokens.compactMap { Int($0) }
        let filtered = values.filter { $0 >= 1024 && $0 <= 65535 }
        let unique = Set(filtered)
        if unique.count <= 40 {
            return unique.sorted()
        }
        return Array(unique.sorted().prefix(40))
    }

    private static func probeScript() -> String {
        """
        set -eu
        # Force an initial emission so the controller can transition out of
        # "connecting" even when no ports are detected.
        CMUX_LAST="__cmux_init__"
        while true; do
          if command -v ss >/dev/null 2>&1; then
            PORTS="$(ss -ltnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ {print $1}' | sort -n -u | tr '\\n' ' ')"
          elif command -v netstat >/dev/null 2>&1; then
            PORTS="$(netstat -lnt 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ {print $1}' | sort -n -u | tr '\\n' ' ')"
          else
            PORTS=""
          fi
          if [ "$PORTS" != "$CMUX_LAST" ]; then
            echo "$PORTS"
            CMUX_LAST="$PORTS"
          fi
          sleep 2
        done
        """
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func mapUnameOS(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "linux":
            return "linux"
        case "darwin":
            return "darwin"
        case "freebsd":
            return "freebsd"
        default:
            return nil
        }
    }

    private static func mapUnameArch(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "x86_64", "amd64":
            return "amd64"
        case "aarch64", "arm64":
            return "arm64"
        case "armv7l":
            return "arm"
        default:
            return nil
        }
    }

    private static func remoteDaemonVersion() -> String {
        let bundleVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let bundleVersion, !bundleVersion.isEmpty {
            return bundleVersion
        }
        return "dev"
    }

    private static func remoteDaemonPath(version: String, goOS: String, goArch: String) -> String {
        ".cmux/bin/cmuxd-remote/\(version)/\(goOS)-\(goArch)/cmuxd-remote"
    }

    private static func which(_ executable: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for component in path.split(separator: ":") {
            let candidate = String(component) + "/" + executable
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func findRepoRoot() -> URL? {
        var candidates: [URL] = []
        let compileTimeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
        candidates.append(compileTimeRoot)
        let environment = ProcessInfo.processInfo.environment
        if let envRoot = environment["CMUX_REMOTE_DAEMON_SOURCE_ROOT"],
           !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
        }
        if let envRoot = environment["CMUXTERM_REPO_ROOT"],
           !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executable)
            candidates.append(executable.deletingLastPathComponent())
            candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent())
        }

        let fm = FileManager.default
        for base in candidates {
            var cursor = base.standardizedFileURL
            for _ in 0..<10 {
                let marker = cursor.appendingPathComponent("daemon/remote/go.mod").path
                if fm.fileExists(atPath: marker) {
                    return cursor
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path {
                    break
                }
                cursor = parent
            }
        }
        return nil
    }

    private static func bestErrorLine(stderr: String, stdout: String = "") -> String? {
        if let stderrLine = meaningfulErrorLine(in: stderr) {
            return stderrLine
        }
        if let stdoutLine = meaningfulErrorLine(in: stdout) {
            return stdoutLine
        }
        return nil
    }

    private static func meaningfulErrorLine(in text: String) -> String? {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() where !isNoiseLine(line) {
            return line
        }
        return lines.last
    }

    private static func isNoiseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("warning: permanently added") { return true }
        if lowered.hasPrefix("debug") { return true }
        if lowered.hasPrefix("transferred:") { return true }
        if lowered.hasPrefix("openbsd_") { return true }
        if lowered.contains("pseudo-terminal will not be allocated") { return true }
        return false
    }

    private static func retrySuffix(retry: Int, delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return " (retry \(retry) in \(seconds)s)"
    }

    /// Kills orphaned SSH relay processes from previous app sessions.
    /// These processes survive app restarts because `pkill` doesn't trigger graceful cleanup.
    private static func killOrphanedRelayProcesses(relayPort: Int, socketPath: String, destination: String) {
        guard relayPort > 0 else { return }
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        let socketPathPattern = NSRegularExpression.escapedPattern(for: socketPath)
        let destinationPattern = NSRegularExpression.escapedPattern(for: destination)
        let relayPattern = "ssh.*-R[[:space:]]*127\\.0\\.0\\.1:\(relayPort):\(socketPathPattern).*\(destinationPattern)"
        process.arguments = ["-f", relayPattern]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Best-effort cleanup; ignore failures
        }
    }

    private static func isLoopbackPortAvailable(port: Int) -> Bool {
        guard port > 0 && port <= 65535 else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }

    /// Check if a port on 127.0.0.1 is already accepting connections (e.g. forwarded by another workspace).
    private static func isLoopbackPortReachable(port: Int) -> Bool {
        guard port > 0 && port <= 65535 else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

enum SidebarLogLevel: String {
    case info
    case progress
    case success
    case warning
    case error
}

struct SidebarLogEntry {
    let message: String
    let level: SidebarLogLevel
    let source: String?
    let timestamp: Date
}

struct SidebarProgressState {
    let value: Double
    let label: String?
}

struct SidebarGitBranchState {
    let branch: String
    let isDirty: Bool
}

enum SidebarPullRequestStatus: String {
    case open
    case merged
    case closed
}

struct SidebarPullRequestState: Equatable {
    let number: Int
    let label: String
    let url: URL
    let status: SidebarPullRequestStatus
}

enum SidebarBranchOrdering {
    struct BranchEntry: Equatable {
        let name: String
        let isDirty: Bool
    }

    struct BranchDirectoryEntry: Equatable {
        let branch: String?
        let isDirty: Bool
        let directory: String?
    }

    static func orderedPaneIds(tree: ExternalTreeNode) -> [String] {
        switch tree {
        case .pane(let pane):
            return [pane.id]
        case .split(let split):
            return orderedPaneIds(tree: split.first) + orderedPaneIds(tree: split.second)
        }
    }

    static func orderedPanelIds(
        tree: ExternalTreeNode,
        paneTabs: [String: [UUID]],
        fallbackPanelIds: [UUID]
    ) -> [UUID] {
        var ordered: [UUID] = []
        var seen: Set<UUID> = []

        for paneId in orderedPaneIds(tree: tree) {
            for panelId in paneTabs[paneId] ?? [] {
                if seen.insert(panelId).inserted {
                    ordered.append(panelId)
                }
            }
        }

        for panelId in fallbackPanelIds {
            if seen.insert(panelId).inserted {
                ordered.append(panelId)
            }
        }

        return ordered
    }

    static func orderedUniqueBranches(
        orderedPanelIds: [UUID],
        panelBranches: [UUID: SidebarGitBranchState],
        fallbackBranch: SidebarGitBranchState?
    ) -> [BranchEntry] {
        var orderedNames: [String] = []
        var branchDirty: [String: Bool] = [:]

        for panelId in orderedPanelIds {
            guard let state = panelBranches[panelId] else { continue }
            let name = state.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            if branchDirty[name] == nil {
                orderedNames.append(name)
                branchDirty[name] = state.isDirty
            } else if state.isDirty {
                branchDirty[name] = true
            }
        }

        if orderedNames.isEmpty, let fallbackBranch {
            let name = fallbackBranch.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return [BranchEntry(name: name, isDirty: fallbackBranch.isDirty)]
            }
        }

        return orderedNames.map { name in
            BranchEntry(name: name, isDirty: branchDirty[name] ?? false)
        }
    }

    static func orderedUniquePullRequests(
        orderedPanelIds: [UUID],
        panelPullRequests: [UUID: SidebarPullRequestState],
        fallbackPullRequest: SidebarPullRequestState?
    ) -> [SidebarPullRequestState] {
        func statusPriority(_ status: SidebarPullRequestStatus) -> Int {
            switch status {
            case .merged: return 3
            case .open: return 2
            case .closed: return 1
            }
        }

        func normalizedReviewURLKey(for url: URL) -> String {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url.absoluteString
            }
            components.query = nil
            components.fragment = nil
            let scheme = components.scheme?.lowercased() ?? ""
            let host = components.host?.lowercased() ?? ""
            let port = components.port.map { ":\($0)" } ?? ""
            var path = components.path
            if path.hasSuffix("/"), path.count > 1 {
                path.removeLast()
            }
            return "\(scheme)://\(host)\(port)\(path)"
        }

        func reviewKey(for state: SidebarPullRequestState) -> String {
            "\(state.label.lowercased())#\(state.number)|\(normalizedReviewURLKey(for: state.url))"
        }

        var orderedKeys: [String] = []
        var pullRequestsByKey: [String: SidebarPullRequestState] = [:]

        for panelId in orderedPanelIds {
            guard let state = panelPullRequests[panelId] else { continue }
            let key = reviewKey(for: state)
            if pullRequestsByKey[key] == nil {
                orderedKeys.append(key)
                pullRequestsByKey[key] = state
                continue
            }
            guard let existing = pullRequestsByKey[key] else { continue }
            if statusPriority(state.status) > statusPriority(existing.status) {
                pullRequestsByKey[key] = state
            }
        }

        if orderedKeys.isEmpty, let fallbackPullRequest {
            return [fallbackPullRequest]
        }

        return orderedKeys.compactMap { pullRequestsByKey[$0] }
    }

    static func orderedUniqueBranchDirectoryEntries(
        orderedPanelIds: [UUID],
        panelBranches: [UUID: SidebarGitBranchState],
        panelDirectories: [UUID: String],
        defaultDirectory: String?,
        fallbackBranch: SidebarGitBranchState?
    ) -> [BranchDirectoryEntry] {
        struct EntryKey: Hashable {
            let directory: String?
            let branch: String?
        }

        struct MutableEntry {
            var branch: String?
            var isDirty: Bool
            var directory: String?
        }

        func normalized(_ text: String?) -> String? {
            guard let text else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        func canonicalDirectoryKey(_ directory: String?) -> String? {
            guard let directory = normalized(directory) else { return nil }
            let expanded = NSString(string: directory).expandingTildeInPath
            let standardized = NSString(string: expanded).standardizingPath
            let cleaned = standardized.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }

        let normalizedFallbackBranch = normalized(fallbackBranch?.branch)
        let shouldUseFallbackBranchPerPanel = !orderedPanelIds.contains {
            normalized(panelBranches[$0]?.branch) != nil
        }
        let defaultBranchForPanels = shouldUseFallbackBranchPerPanel ? normalizedFallbackBranch : nil
        let defaultBranchDirty = shouldUseFallbackBranchPerPanel ? (fallbackBranch?.isDirty ?? false) : false

        var order: [EntryKey] = []
        var entries: [EntryKey: MutableEntry] = [:]

        for panelId in orderedPanelIds {
            let panelBranch = normalized(panelBranches[panelId]?.branch)
            let branch = panelBranch ?? defaultBranchForPanels
            let directory = normalized(panelDirectories[panelId] ?? defaultDirectory)
            guard branch != nil || directory != nil else { continue }

            let panelDirty = panelBranch != nil
                ? (panelBranches[panelId]?.isDirty ?? false)
                : defaultBranchDirty

            let key: EntryKey
            if let directoryKey = canonicalDirectoryKey(directory) {
                key = EntryKey(directory: directoryKey, branch: nil)
            } else {
                key = EntryKey(directory: nil, branch: branch)
            }

            if entries[key] == nil {
                order.append(key)
                entries[key] = MutableEntry(
                    branch: branch,
                    isDirty: panelDirty,
                    directory: directory
                )
            } else {
                if panelDirty {
                    entries[key]?.isDirty = true
                }
                if let branch {
                    entries[key]?.branch = branch
                }
                if let directory {
                    entries[key]?.directory = directory
                }
            }
        }

        if order.isEmpty, let fallbackBranch {
            let branch = normalized(fallbackBranch.branch)
            let directory = normalized(defaultDirectory)
            if branch != nil || directory != nil {
                return [BranchDirectoryEntry(
                    branch: branch,
                    isDirty: fallbackBranch.isDirty,
                    directory: directory
                )]
            }
        }

        return order.compactMap { key in
            guard let entry = entries[key] else { return nil }
            return BranchDirectoryEntry(
                branch: entry.branch,
                isDirty: entry.isDirty,
                directory: entry.directory
            )
        }
    }
}

enum WorkspaceRemoteConnectionState: String {
    case disconnected
    case connecting
    case connected
    case error
}

enum WorkspaceRemoteDaemonState: String {
    case unavailable
    case bootstrapping
    case ready
    case error
}

struct WorkspaceRemoteDaemonStatus: Equatable {
    var state: WorkspaceRemoteDaemonState = .unavailable
    var detail: String?
    var version: String?
    var name: String?
    var capabilities: [String] = []
    var remotePath: String?

    func payload() -> [String: Any] {
        [
            "state": state.rawValue,
            "detail": detail ?? NSNull(),
            "version": version ?? NSNull(),
            "name": name ?? NSNull(),
            "capabilities": capabilities,
            "remote_path": remotePath ?? NSNull(),
        ]
    }
}

struct WorkspaceRemoteConfiguration: Equatable {
    let destination: String
    let port: Int?
    let identityFile: String?
    let sshOptions: [String]
    let localProxyPort: Int?
    let relayPort: Int?
    let localSocketPath: String?

    var displayTarget: String {
        guard let port else { return destination }
        return "\(destination):\(port)"
    }
}

struct ClosedBrowserPanelRestoreSnapshot {
    let workspaceId: UUID
    let url: URL?
    let originalPaneId: UUID
    let originalTabIndex: Int
    let fallbackSplitOrientation: SplitOrientation?
    let fallbackSplitInsertFirst: Bool
    let fallbackAnchorPaneId: UUID?
}

/// Workspace represents a sidebar tab.
/// Each workspace contains one BonsplitController that manages split panes and nested surfaces.
@MainActor
final class Workspace: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    @Published var customTitle: String?
    @Published var isPinned: Bool = false
    @Published var customColor: String?
    @Published var currentDirectory: String

    /// Ordinal for CMUX_PORT range assignment (monotonically increasing per app session)
    var portOrdinal: Int = 0

    /// The bonsplit controller managing the split panes for this workspace
    let bonsplitController: BonsplitController

    /// Mapping from bonsplit TabID to our Panel instances
    @Published private(set) var panels: [UUID: any Panel] = [:]

    /// Subscriptions for panel updates (e.g., browser title changes)
    private var panelSubscriptions: [UUID: AnyCancellable] = [:]

    /// When true, suppresses auto-creation in didSplitPane (programmatic splits handle their own panels)
    private var isProgrammaticSplit = false
    var onClosedBrowserPanel: ((ClosedBrowserPanelRestoreSnapshot) -> Void)?

    nonisolated static func resolvedSnapshotTerminalScrollback(
        capturedScrollback: String?,
        fallbackScrollback: String?
    ) -> String? {
        if let captured = SessionPersistencePolicy.truncatedScrollback(capturedScrollback) {
            return captured
        }
        return SessionPersistencePolicy.truncatedScrollback(fallbackScrollback)
    }

    func sessionSnapshot(includeScrollback: Bool) -> SessionWorkspaceSnapshot {
        let tree = bonsplitController.treeSnapshot()
        let layout = sessionLayoutSnapshot(from: tree)

        let orderedPanelIds = sidebarOrderedPanelIds()
        var seen: Set<UUID> = []
        var allPanelIds: [UUID] = []
        for panelId in orderedPanelIds where seen.insert(panelId).inserted {
            allPanelIds.append(panelId)
        }
        for panelId in panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) where seen.insert(panelId).inserted {
            allPanelIds.append(panelId)
        }

        let panelSnapshots = allPanelIds
            .prefix(SessionPersistencePolicy.maxPanelsPerWorkspace)
            .compactMap { sessionPanelSnapshot(panelId: $0, includeScrollback: includeScrollback) }

        let statusSnapshots = statusEntries.values
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { entry in
                SessionStatusEntrySnapshot(
                    key: entry.key,
                    value: entry.value,
                    icon: entry.icon,
                    color: entry.color,
                    timestamp: entry.timestamp.timeIntervalSince1970
                )
            }
        let logSnapshots = logEntries.map { entry in
            SessionLogEntrySnapshot(
                message: entry.message,
                level: entry.level.rawValue,
                source: entry.source,
                timestamp: entry.timestamp.timeIntervalSince1970
            )
        }

        let progressSnapshot = progress.map { progress in
            SessionProgressSnapshot(value: progress.value, label: progress.label)
        }
        let gitBranchSnapshot = gitBranch.map { branch in
            SessionGitBranchSnapshot(branch: branch.branch, isDirty: branch.isDirty)
        }

        return SessionWorkspaceSnapshot(
            processTitle: processTitle,
            customTitle: customTitle,
            customColor: customColor,
            isPinned: isPinned,
            currentDirectory: currentDirectory,
            focusedPanelId: focusedPanelId,
            layout: layout,
            panels: panelSnapshots,
            statusEntries: statusSnapshots,
            logEntries: logSnapshots,
            progress: progressSnapshot,
            gitBranch: gitBranchSnapshot
        )
    }

    func restoreSessionSnapshot(_ snapshot: SessionWorkspaceSnapshot) {
        restoredTerminalScrollbackByPanelId.removeAll(keepingCapacity: false)

        let normalizedCurrentDirectory = snapshot.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedCurrentDirectory.isEmpty {
            currentDirectory = normalizedCurrentDirectory
        }

        let panelSnapshotsById = Dictionary(uniqueKeysWithValues: snapshot.panels.map { ($0.id, $0) })
        let leafEntries = restoreSessionLayout(snapshot.layout)
        var oldToNewPanelIds: [UUID: UUID] = [:]

        for entry in leafEntries {
            restorePane(
                entry.paneId,
                snapshot: entry.snapshot,
                panelSnapshotsById: panelSnapshotsById,
                oldToNewPanelIds: &oldToNewPanelIds
            )
        }

        pruneSurfaceMetadata(validSurfaceIds: Set(panels.keys))
        applySessionDividerPositions(snapshotNode: snapshot.layout, liveNode: bonsplitController.treeSnapshot())

        applyProcessTitle(snapshot.processTitle)
        setCustomTitle(snapshot.customTitle)
        setCustomColor(snapshot.customColor)
        isPinned = snapshot.isPinned

        statusEntries = Dictionary(
            uniqueKeysWithValues: snapshot.statusEntries.map { entry in
                (
                    entry.key,
                    SidebarStatusEntry(
                        key: entry.key,
                        value: entry.value,
                        icon: entry.icon,
                        color: entry.color,
                        timestamp: Date(timeIntervalSince1970: entry.timestamp)
                    )
                )
            }
        )
        logEntries = snapshot.logEntries.map { entry in
            SidebarLogEntry(
                message: entry.message,
                level: SidebarLogLevel(rawValue: entry.level) ?? .info,
                source: entry.source,
                timestamp: Date(timeIntervalSince1970: entry.timestamp)
            )
        }
        progress = snapshot.progress.map { SidebarProgressState(value: $0.value, label: $0.label) }
        gitBranch = snapshot.gitBranch.map { SidebarGitBranchState(branch: $0.branch, isDirty: $0.isDirty) }

        recomputeListeningPorts()

        if let focusedOldPanelId = snapshot.focusedPanelId,
           let focusedNewPanelId = oldToNewPanelIds[focusedOldPanelId],
           panels[focusedNewPanelId] != nil {
            focusPanel(focusedNewPanelId)
        } else if let fallbackFocusedPanelId = focusedPanelId, panels[fallbackFocusedPanelId] != nil {
            focusPanel(fallbackFocusedPanelId)
        } else {
            scheduleFocusReconcile()
        }
    }

    private func sessionLayoutSnapshot(from node: ExternalTreeNode) -> SessionWorkspaceLayoutSnapshot {
        switch node {
        case .pane(let pane):
            let panelIds = sessionPanelIDs(for: pane)
            let selectedPanelId = pane.selectedTabId.flatMap(sessionPanelID(forExternalTabIDString:))
            return .pane(
                SessionPaneLayoutSnapshot(
                    panelIds: panelIds,
                    selectedPanelId: selectedPanelId
                )
            )
        case .split(let split):
            return .split(
                SessionSplitLayoutSnapshot(
                    orientation: split.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    dividerPosition: split.dividerPosition,
                    first: sessionLayoutSnapshot(from: split.first),
                    second: sessionLayoutSnapshot(from: split.second)
                )
            )
        }
    }

    private func sessionPanelIDs(for pane: ExternalPaneNode) -> [UUID] {
        var panelIds: [UUID] = []
        var seen = Set<UUID>()
        for tab in pane.tabs {
            guard let panelId = sessionPanelID(forExternalTabIDString: tab.id) else { continue }
            if seen.insert(panelId).inserted {
                panelIds.append(panelId)
            }
        }
        return panelIds
    }

    private func sessionPanelID(forExternalTabIDString tabIDString: String) -> UUID? {
        guard let tabUUID = UUID(uuidString: tabIDString) else { return nil }
        for (surfaceId, panelId) in surfaceIdToPanelId {
            guard let surfaceUUID = sessionSurfaceUUID(for: surfaceId) else { continue }
            if surfaceUUID == tabUUID {
                return panelId
            }
        }
        return nil
    }

    private func sessionSurfaceUUID(for surfaceId: TabID) -> UUID? {
        struct EncodedSurfaceID: Decodable {
            let id: UUID
        }

        guard let data = try? JSONEncoder().encode(surfaceId),
              let decoded = try? JSONDecoder().decode(EncodedSurfaceID.self, from: data) else {
            return nil
        }
        return decoded.id
    }

    private func sessionPanelSnapshot(panelId: UUID, includeScrollback: Bool) -> SessionPanelSnapshot? {
        guard let panel = panels[panelId] else { return nil }

        let panelTitle = panelTitle(panelId: panelId)
        let customTitle = panelCustomTitles[panelId]
        let directory = panelDirectories[panelId]
        let isPinned = pinnedPanelIds.contains(panelId)
        let isManuallyUnread = manualUnreadPanelIds.contains(panelId)
        let branchSnapshot = panelGitBranches[panelId].map {
            SessionGitBranchSnapshot(branch: $0.branch, isDirty: $0.isDirty)
        }
        let listeningPorts = (surfaceListeningPorts[panelId] ?? []).sorted()
        let ttyName = surfaceTTYNames[panelId]

        let terminalSnapshot: SessionTerminalPanelSnapshot?
        let browserSnapshot: SessionBrowserPanelSnapshot?
        let markdownSnapshot: SessionMarkdownPanelSnapshot?
        switch panel.panelType {
        case .terminal:
            guard let _ = panel as? TerminalPanel else { return nil }
            let resolvedScrollback = terminalSnapshotScrollback(
                panelId: panelId,
                capturedScrollback: nil,
                includeScrollback: includeScrollback
            )
            terminalSnapshot = SessionTerminalPanelSnapshot(
                workingDirectory: panelDirectories[panelId],
                scrollback: resolvedScrollback
            )
            browserSnapshot = nil
            markdownSnapshot = nil
        case .browser:
            guard let browserPanel = panel as? BrowserPanel else { return nil }
            terminalSnapshot = nil
            let historySnapshot = browserPanel.sessionNavigationHistorySnapshot()
            browserSnapshot = SessionBrowserPanelSnapshot(
                urlString: browserPanel.preferredURLStringForOmnibar(),
                shouldRenderWebView: browserPanel.shouldRenderWebView,
                pageZoom: Double(browserPanel.webView.pageZoom),
                developerToolsVisible: browserPanel.isDeveloperToolsVisible(),
                backHistoryURLStrings: historySnapshot.backHistoryURLStrings,
                forwardHistoryURLStrings: historySnapshot.forwardHistoryURLStrings
            )
            markdownSnapshot = nil
        case .markdown:
            guard let mdPanel = panel as? MarkdownPanel else { return nil }
            terminalSnapshot = nil
            browserSnapshot = nil
            markdownSnapshot = SessionMarkdownPanelSnapshot(filePath: mdPanel.filePath)
        }

        return SessionPanelSnapshot(
            id: panelId,
            type: panel.panelType,
            title: panelTitle,
            customTitle: customTitle,
            directory: directory,
            isPinned: isPinned,
            isManuallyUnread: isManuallyUnread,
            gitBranch: branchSnapshot,
            listeningPorts: listeningPorts,
            ttyName: ttyName,
            terminal: terminalSnapshot,
            browser: browserSnapshot,
            markdown: markdownSnapshot
        )
    }

    private func terminalSnapshotScrollback(
        panelId: UUID,
        capturedScrollback: String?,
        includeScrollback: Bool
    ) -> String? {
        guard includeScrollback else { return nil }
        let fallback = restoredTerminalScrollbackByPanelId[panelId]
        let resolved = Self.resolvedSnapshotTerminalScrollback(
            capturedScrollback: capturedScrollback,
            fallbackScrollback: fallback
        )
        if let resolved {
            restoredTerminalScrollbackByPanelId[panelId] = resolved
        } else {
            restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
        }
        return resolved
    }

    private func restoreSessionLayout(_ layout: SessionWorkspaceLayoutSnapshot) -> [SessionPaneRestoreEntry] {
        guard let rootPaneId = bonsplitController.allPaneIds.first else {
            return []
        }

        var leaves: [SessionPaneRestoreEntry] = []
        restoreSessionLayoutNode(layout, inPane: rootPaneId, leaves: &leaves)
        return leaves
    }

    private func restoreSessionLayoutNode(
        _ node: SessionWorkspaceLayoutSnapshot,
        inPane paneId: PaneID,
        leaves: inout [SessionPaneRestoreEntry]
    ) {
        switch node {
        case .pane(let pane):
            leaves.append(SessionPaneRestoreEntry(paneId: paneId, snapshot: pane))
        case .split(let split):
            var anchorPanelId = bonsplitController
                .tabs(inPane: paneId)
                .compactMap { panelIdFromSurfaceId($0.id) }
                .first

            if anchorPanelId == nil {
                anchorPanelId = newTerminalSurface(inPane: paneId, focus: false)?.id
            }

            guard let anchorPanelId,
                  let newSplitPanel = newTerminalSplit(
                    from: anchorPanelId,
                    orientation: split.orientation.splitOrientation,
                    insertFirst: false,
                    focus: false
                  ),
                  let secondPaneId = self.paneId(forPanelId: newSplitPanel.id) else {
                leaves.append(
                    SessionPaneRestoreEntry(
                        paneId: paneId,
                        snapshot: SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)
                    )
                )
                return
            }

            restoreSessionLayoutNode(split.first, inPane: paneId, leaves: &leaves)
            restoreSessionLayoutNode(split.second, inPane: secondPaneId, leaves: &leaves)
        }
    }

    private func restorePane(
        _ paneId: PaneID,
        snapshot: SessionPaneLayoutSnapshot,
        panelSnapshotsById: [UUID: SessionPanelSnapshot],
        oldToNewPanelIds: inout [UUID: UUID]
    ) {
        let existingPanelIds = bonsplitController
            .tabs(inPane: paneId)
            .compactMap { panelIdFromSurfaceId($0.id) }
        let desiredOldPanelIds = snapshot.panelIds.filter { panelSnapshotsById[$0] != nil }

        var createdPanelIds: [UUID] = []
        for oldPanelId in desiredOldPanelIds {
            guard let panelSnapshot = panelSnapshotsById[oldPanelId] else { continue }
            guard let createdPanelId = createPanel(from: panelSnapshot, inPane: paneId) else { continue }
            createdPanelIds.append(createdPanelId)
            oldToNewPanelIds[oldPanelId] = createdPanelId
        }

        guard !createdPanelIds.isEmpty else { return }

        for oldPanelId in existingPanelIds where !createdPanelIds.contains(oldPanelId) {
            _ = closePanel(oldPanelId, force: true)
        }

        for (index, panelId) in createdPanelIds.enumerated() {
            _ = reorderSurface(panelId: panelId, toIndex: index)
        }

        let selectedPanelId: UUID? = {
            if let selectedOldId = snapshot.selectedPanelId {
                return oldToNewPanelIds[selectedOldId]
            }
            return createdPanelIds.first
        }()

        if let selectedPanelId,
           let selectedTabId = surfaceIdFromPanelId(selectedPanelId) {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(selectedTabId)
        }
    }

    private func createPanel(from snapshot: SessionPanelSnapshot, inPane paneId: PaneID) -> UUID? {
        switch snapshot.type {
        case .terminal:
            let workingDirectory = snapshot.terminal?.workingDirectory ?? snapshot.directory ?? currentDirectory
            let replayEnvironment = SessionScrollbackReplayStore.replayEnvironment(
                for: snapshot.terminal?.scrollback
            )
            guard let terminalPanel = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: workingDirectory,
                startupEnvironment: replayEnvironment
            ) else {
                return nil
            }
            let fallbackScrollback = SessionPersistencePolicy.truncatedScrollback(snapshot.terminal?.scrollback)
            if let fallbackScrollback {
                restoredTerminalScrollbackByPanelId[terminalPanel.id] = fallbackScrollback
            } else {
                restoredTerminalScrollbackByPanelId.removeValue(forKey: terminalPanel.id)
            }
            applySessionPanelMetadata(snapshot, toPanelId: terminalPanel.id)
            return terminalPanel.id
        case .browser:
            let initialURL = snapshot.browser?.urlString.flatMap { URL(string: $0) }
            guard let browserPanel = newBrowserSurface(
                inPane: paneId,
                url: initialURL,
                focus: false
            ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: browserPanel.id)
            return browserPanel.id
        case .markdown:
            guard let filePath = snapshot.markdown?.filePath else {
                return nil
            }
            guard let markdownPanel = newMarkdownSurface(
                inPane: paneId,
                filePath: filePath,
                focus: false
            ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: markdownPanel.id)
            return markdownPanel.id
        }
    }

    private func applySessionPanelMetadata(_ snapshot: SessionPanelSnapshot, toPanelId panelId: UUID) {
        if let title = snapshot.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            panelTitles[panelId] = title
        }

        setPanelCustomTitle(panelId: panelId, title: snapshot.customTitle)
        setPanelPinned(panelId: panelId, pinned: snapshot.isPinned)

        if snapshot.isManuallyUnread {
            markPanelUnread(panelId)
        } else {
            clearManualUnread(panelId: panelId)
        }

        if let directory = snapshot.directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
            updatePanelDirectory(panelId: panelId, directory: directory)
        }

        if let branch = snapshot.gitBranch {
            panelGitBranches[panelId] = SidebarGitBranchState(branch: branch.branch, isDirty: branch.isDirty)
        } else {
            panelGitBranches.removeValue(forKey: panelId)
        }

        surfaceListeningPorts[panelId] = Array(Set(snapshot.listeningPorts)).sorted()

        if let ttyName = snapshot.ttyName?.trimmingCharacters(in: .whitespacesAndNewlines), !ttyName.isEmpty {
            surfaceTTYNames[panelId] = ttyName
        } else {
            surfaceTTYNames.removeValue(forKey: panelId)
        }

        if let browserSnapshot = snapshot.browser,
           let browserPanel = browserPanel(for: panelId) {
            browserPanel.restoreSessionNavigationHistory(
                backHistoryURLStrings: browserSnapshot.backHistoryURLStrings ?? [],
                forwardHistoryURLStrings: browserSnapshot.forwardHistoryURLStrings ?? [],
                currentURLString: browserSnapshot.urlString
            )

            let pageZoom = CGFloat(max(0.25, min(5.0, browserSnapshot.pageZoom)))
            if pageZoom.isFinite {
                browserPanel.webView.pageZoom = pageZoom
            }

            if browserSnapshot.developerToolsVisible {
                _ = browserPanel.showDeveloperTools()
                browserPanel.requestDeveloperToolsRefreshAfterNextAttach(reason: "session_restore")
            } else {
                _ = browserPanel.hideDeveloperTools()
            }
        }
    }

    private func applySessionDividerPositions(
        snapshotNode: SessionWorkspaceLayoutSnapshot,
        liveNode: ExternalTreeNode
    ) {
        switch (snapshotNode, liveNode) {
        case (.split(let snapshotSplit), .split(let liveSplit)):
            if let splitID = UUID(uuidString: liveSplit.id) {
                _ = bonsplitController.setDividerPosition(
                    CGFloat(snapshotSplit.dividerPosition),
                    forSplit: splitID,
                    fromExternal: true
                )
            }
            applySessionDividerPositions(snapshotNode: snapshotSplit.first, liveNode: liveSplit.first)
            applySessionDividerPositions(snapshotNode: snapshotSplit.second, liveNode: liveSplit.second)
        default:
            return
        }
    }
}

private final class WorkspaceRemoteDaemonRPCClient {
    private static let maxStdoutBufferBytes = 256 * 1024

    private let configuration: WorkspaceRemoteConfiguration
    private let remotePath: String
    private let onUnexpectedTermination: (String) -> Void
    private let callQueue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.call.\(UUID().uuidString)")
    private let stateQueue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.state.\(UUID().uuidString)")

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var isClosed = true
    private var shouldReportTermination = true

    private var nextRequestID = 1
    private var pendingID: Int?
    private var pendingSemaphore: DispatchSemaphore?
    private var pendingResponse: [String: Any]?
    private var pendingFailureMessage: String?

    private var stdoutBuffer = Data()
    private var stderrBuffer = ""

    init(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUnexpectedTermination: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.remotePath = remotePath
        self.onUnexpectedTermination = onUnexpectedTermination
    }

    func start() throws {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.daemonArguments(configuration: configuration, remotePath: remotePath)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.stateQueue.async {
                self?.consumeStdoutData(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.stateQueue.async {
                self?.consumeStderrData(data)
            }
        }
        process.terminationHandler = { [weak self] terminated in
            self?.stateQueue.async {
                self?.handleProcessTermination(terminated)
            }
        }

        do {
            try process.run()
        } catch {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch SSH daemon transport: \(error.localizedDescription)",
            ])
        }

        stateQueue.sync {
            self.process = process
            self.stdinHandle = stdinPipe.fileHandleForWriting
            self.stdoutHandle = stdoutPipe.fileHandleForReading
            self.stderrHandle = stderrPipe.fileHandleForReading
            self.isClosed = false
            self.shouldReportTermination = true
            self.stdoutBuffer = Data()
            self.stderrBuffer = ""
            self.pendingID = nil
            self.pendingSemaphore = nil
            self.pendingResponse = nil
            self.pendingFailureMessage = nil
        }

        do {
            let hello = try call(method: "hello", params: [:], timeout: 8.0)
            let capabilities = (hello["capabilities"] as? [String]) ?? []
            guard capabilities.contains("proxy.stream") else {
                throw NSError(domain: "cmux.remote.daemon.rpc", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon missing required capability proxy.stream",
                ])
            }
        } catch {
            stop(suppressTerminationCallback: true)
            throw error
        }
    }

    func stop() {
        stop(suppressTerminationCallback: true)
    }

    func openStream(host: String, port: Int, timeoutMs: Int = 10000) throws -> String {
        let result = try call(
            method: "proxy.open",
            params: [
                "host": host,
                "port": port,
                "timeout_ms": timeoutMs,
            ],
            timeout: 12.0
        )
        let streamID = (result["stream_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !streamID.isEmpty else {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "proxy.open missing stream_id",
            ])
        }
        return streamID
    }

    func writeStream(streamID: String, data: Data) throws {
        _ = try call(
            method: "proxy.write",
            params: [
                "stream_id": streamID,
                "data_base64": data.base64EncodedString(),
            ],
            timeout: 8.0
        )
    }

    func readStream(streamID: String, maxBytes: Int = 32768, timeoutMs: Int = 250) throws -> (data: Data, eof: Bool) {
        let result = try call(
            method: "proxy.read",
            params: [
                "stream_id": streamID,
                "max_bytes": maxBytes,
                "timeout_ms": timeoutMs,
            ],
            timeout: max(2.0, TimeInterval(timeoutMs) / 1000.0 + 2.0)
        )
        let encoded = (result["data_base64"] as? String) ?? ""
        let decoded = encoded.isEmpty ? Data() : (Data(base64Encoded: encoded) ?? Data())
        let eof = (result["eof"] as? Bool) ?? false
        return (decoded, eof)
    }

    func closeStream(streamID: String) {
        _ = try? call(
            method: "proxy.close",
            params: ["stream_id": streamID],
            timeout: 4.0
        )
    }

    private func call(method: String, params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        try callQueue.sync {
            let semaphore = DispatchSemaphore(value: 0)
            let requestID: Int = stateQueue.sync {
                let id = nextRequestID
                nextRequestID += 1
                pendingID = id
                pendingSemaphore = semaphore
                pendingResponse = nil
                pendingFailureMessage = nil
                return id
            }

            let payload: Data
            do {
                payload = try Self.encodeJSON([
                    "id": requestID,
                    "method": method,
                    "params": params,
                ])
            } catch {
                stateQueue.sync {
                    clearPendingLocked()
                }
                throw NSError(domain: "cmux.remote.daemon.rpc", code: 10, userInfo: [
                    NSLocalizedDescriptionKey: "failed to encode daemon RPC request \(method): \(error.localizedDescription)",
                ])
            }

            do {
                try writePayload(payload)
            } catch {
                stateQueue.sync {
                    clearPendingLocked()
                }
                throw error
            }

            if semaphore.wait(timeout: .now() + timeout) == .timedOut {
                stop(suppressTerminationCallback: false)
                throw NSError(domain: "cmux.remote.daemon.rpc", code: 11, userInfo: [
                    NSLocalizedDescriptionKey: "daemon RPC timeout waiting for \(method) response",
                ])
            }

            let response: [String: Any] = try stateQueue.sync {
                defer {
                    clearPendingLocked()
                }
                if let failure = pendingFailureMessage {
                    throw NSError(domain: "cmux.remote.daemon.rpc", code: 12, userInfo: [
                        NSLocalizedDescriptionKey: failure,
                    ])
                }
                guard let pendingResponse else {
                    throw NSError(domain: "cmux.remote.daemon.rpc", code: 13, userInfo: [
                        NSLocalizedDescriptionKey: "daemon RPC \(method) returned empty response",
                    ])
                }
                return pendingResponse
            }

            let ok = (response["ok"] as? Bool) ?? false
            if ok {
                return (response["result"] as? [String: Any]) ?? [:]
            }

            let errorObject = (response["error"] as? [String: Any]) ?? [:]
            let code = (errorObject["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "rpc_error"
            let message = (errorObject["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "daemon RPC call failed"
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "\(method) failed (\(code)): \(message)",
            ])
        }
    }

    private func writePayload(_ payload: Data) throws {
        let stdinHandle: FileHandle = stateQueue.sync {
            self.stdinHandle ?? FileHandle.nullDevice
        }
        if stdinHandle === FileHandle.nullDevice {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 15, userInfo: [
                NSLocalizedDescriptionKey: "daemon transport is not connected",
            ])
        }
        do {
            try stdinHandle.write(contentsOf: payload)
            try stdinHandle.write(contentsOf: Data([0x0A]))
        } catch {
            stop(suppressTerminationCallback: false)
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 16, userInfo: [
                NSLocalizedDescriptionKey: "failed writing daemon RPC request: \(error.localizedDescription)",
            ])
        }
    }

    private func consumeStdoutData(_ data: Data) {
        guard !data.isEmpty else {
            signalPendingFailureLocked("daemon transport closed stdout")
            return
        }

        stdoutBuffer.append(data)
        if stdoutBuffer.count > Self.maxStdoutBufferBytes {
            stdoutBuffer.removeAll(keepingCapacity: false)
            signalPendingFailureLocked("daemon transport stdout exceeded \(Self.maxStdoutBufferBytes) bytes without message framing")
            process?.terminate()
            return
        }
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            var lineData = Data(stdoutBuffer[..<newlineIndex])
            stdoutBuffer.removeSubrange(...newlineIndex)

            if let carriageIndex = lineData.lastIndex(of: 0x0D), carriageIndex == lineData.index(before: lineData.endIndex) {
                lineData.remove(at: carriageIndex)
            }
            guard !lineData.isEmpty else { continue }

            guard let payload = try? JSONSerialization.jsonObject(with: lineData, options: []) as? [String: Any] else {
                continue
            }

            let responseID: Int = {
                if let intValue = payload["id"] as? Int {
                    return intValue
                }
                if let numberValue = payload["id"] as? NSNumber {
                    return numberValue.intValue
                }
                return -1
            }()
            guard responseID >= 0 else { continue }
            guard pendingID == responseID else { continue }

            pendingResponse = payload
            pendingSemaphore?.signal()
        }
    }

    private func consumeStderrData(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        stderrBuffer.append(chunk)
        if stderrBuffer.count > 8192 {
            stderrBuffer.removeFirst(stderrBuffer.count - 8192)
        }
    }

    private func handleProcessTermination(_ process: Process) {
        let shouldNotify: Bool = {
            guard self.process === process else { return false }
            return !isClosed && shouldReportTermination
        }()
        let detail = Self.bestErrorLine(stderr: stderrBuffer) ?? "daemon transport exited with status \(process.terminationStatus)"

        isClosed = true
        self.process = nil
        stdinHandle = nil
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
        signalPendingFailureLocked(detail)

        guard shouldNotify else { return }
        onUnexpectedTermination(detail)
    }

    private func stop(suppressTerminationCallback: Bool) {
        let captured: (Process?, FileHandle?, FileHandle?, FileHandle?) = stateQueue.sync {
            shouldReportTermination = !suppressTerminationCallback
            if isClosed {
                return (nil, nil, nil, nil)
            }

            isClosed = true
            signalPendingFailureLocked("daemon transport stopped")
            let capturedProcess = process
            let capturedStdin = stdinHandle
            let capturedStdout = stdoutHandle
            let capturedStderr = stderrHandle

            process = nil
            stdinHandle = nil
            stdoutHandle = nil
            stderrHandle = nil
            return (capturedProcess, capturedStdin, capturedStdout, capturedStderr)
        }

        captured.2?.readabilityHandler = nil
        captured.3?.readabilityHandler = nil
        try? captured.1?.close()
        try? captured.2?.close()
        try? captured.3?.close()
        if let process = captured.0, process.isRunning {
            process.terminate()
        }
    }

    private func signalPendingFailureLocked(_ message: String) {
        pendingFailureMessage = message
        pendingSemaphore?.signal()
    }

    private func clearPendingLocked() {
        pendingID = nil
        pendingSemaphore = nil
        pendingResponse = nil
        pendingFailureMessage = nil
    }

    private static func encodeJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private static func daemonArguments(configuration: WorkspaceRemoteConfiguration, remotePath: String) -> [String] {
        let script = "exec \(shellSingleQuoted(remotePath)) serve --stdio"
        // Use non-login sh so remote ~/.profile noise does not interfere with daemon transport startup.
        let command = "sh -c \(shellSingleQuoted(script))"
        return sshCommonArguments(configuration: configuration, batchMode: true) + [configuration.destination, command]
    }

    private static let connectionSharingOptionKeys: Set<String> = [
        "controlmaster",
        "controlpersist",
        "controlpath",
    ]

    private static func sshCommonArguments(configuration: WorkspaceRemoteConfiguration, batchMode: Bool) -> [String] {
        let effectiveSSHOptions: [String] = {
            if batchMode {
                return backgroundSSHOptions(configuration.sshOptions)
            }
            return normalizedSSHOptions(configuration.sshOptions)
        }()
        var args: [String] = [
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
        ]
        if !hasSSHOptionKey(effectiveSSHOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        if batchMode {
            args += ["-o", "BatchMode=yes"]
            // Avoid shared ControlPath lock contention with interactive ssh sessions.
            args += ["-o", "ControlMaster=no"]
        }
        if let port = configuration.port {
            args += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }
        return args
    }

    private static func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        for option in options {
            let token = sshOptionKey(option)
            if token == loweredKey {
                return true
            }
        }
        return false
    }

    private static func normalizedSSHOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }
    }

    private static func backgroundSSHOptions(_ options: [String]) -> [String] {
        normalizedSSHOptions(options).filter { option in
            guard let key = sshOptionKey(option) else { return false }
            return !connectionSharingOptionKeys.contains(key)
        }
    }

    private static func sshOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func bestErrorLine(stderr: String) -> String? {
        let lines = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() where !isNoiseLine(line) {
            return line
        }
        return lines.last
    }

    private static func isNoiseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("warning: permanently added") { return true }
        if lowered.hasPrefix("debug") { return true }
        if lowered.hasPrefix("transferred:") { return true }
        if lowered.hasPrefix("openbsd_") { return true }
        if lowered.contains("pseudo-terminal will not be allocated") { return true }
        return false
    }
}

private final class WorkspaceRemoteDaemonProxyTunnel {
    private final class ProxySession {
        private static let maxHandshakeBytes = 64 * 1024
        private static let remoteLoopbackProxyAliasHost = "cmux-loopback.localtest.me"

        private enum HandshakeProtocol {
            case undecided
            case socks5
            case connect
        }

        private enum SocksStage {
            case greeting
            case request
        }

        private struct SocksRequest {
            let host: String
            let port: Int
            let command: UInt8
            let consumedBytes: Int
        }

        let id = UUID()

        private let connection: NWConnection
        private let rpcClient: WorkspaceRemoteDaemonRPCClient
        private let queue: DispatchQueue
        private let readQueue: DispatchQueue
        private let onClose: (UUID) -> Void

        private var isClosed = false
        private var protocolKind: HandshakeProtocol = .undecided
        private var socksStage: SocksStage = .greeting
        private var handshakeBuffer = Data()
        private var streamID: String?
        private var localInputEOF = false

        init(
            connection: NWConnection,
            rpcClient: WorkspaceRemoteDaemonRPCClient,
            queue: DispatchQueue,
            onClose: @escaping (UUID) -> Void
        ) {
            self.connection = connection
            self.rpcClient = rpcClient
            self.queue = queue
            self.readQueue = DispatchQueue(
                label: "com.cmux.remote-ssh.daemon-tunnel.proxy-read.\(UUID().uuidString)",
                qos: .utility
            )
            self.onClose = onClose
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    self.close(reason: "proxy client connection failed: \(error)")
                case .cancelled:
                    self.close(reason: nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            receiveNext()
        }

        func stop() {
            close(reason: nil)
        }

        private func receiveNext() {
            guard !isClosed else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, isComplete, error in
                guard let self, !self.isClosed else { return }

                if let data, !data.isEmpty {
                    if self.streamID == nil {
                        if self.handshakeBuffer.count + data.count > Self.maxHandshakeBytes {
                            self.close(reason: "proxy handshake exceeded \(Self.maxHandshakeBytes) bytes")
                            return
                        }
                        self.handshakeBuffer.append(data)
                        self.processHandshakeBuffer()
                    } else {
                        self.forwardToRemote(data)
                    }
                }

                if isComplete {
                    // Treat local EOF as a half-close: keep remote read loop alive so we can
                    // drain upstream response bytes (for example curl closing write-side after
                    // sending an HTTP request through SOCKS/CONNECT).
                    self.localInputEOF = true
                    if self.streamID == nil {
                        self.close(reason: nil)
                    }
                    return
                }
                if let error {
                    self.close(reason: "proxy client receive error: \(error)")
                    return
                }

                self.receiveNext()
            }
        }

        private func processHandshakeBuffer() {
            guard !isClosed else { return }
            while streamID == nil {
                switch protocolKind {
                case .undecided:
                    guard let first = handshakeBuffer.first else { return }
                    protocolKind = (first == 0x05) ? .socks5 : .connect
                case .socks5:
                    if !processSocksHandshakeStep() {
                        return
                    }
                case .connect:
                    if !processConnectHandshakeStep() {
                        return
                    }
                }
            }
        }

        private func processSocksHandshakeStep() -> Bool {
            switch socksStage {
            case .greeting:
                guard handshakeBuffer.count >= 2 else { return false }
                let methodCount = Int(handshakeBuffer[1])
                let total = 2 + methodCount
                guard handshakeBuffer.count >= total else { return false }

                let methods = [UInt8](handshakeBuffer[2..<total])
                handshakeBuffer = Data(handshakeBuffer.dropFirst(total))
                socksStage = .request

                if !methods.contains(0x00) {
                    sendAndClose(Data([0x05, 0xFF]))
                    return false
                }
                sendLocal(Data([0x05, 0x00]))
                return true

            case .request:
                let request: SocksRequest
                do {
                    guard let parsed = try parseSocksRequest(from: handshakeBuffer) else { return false }
                    request = parsed
                } catch {
                    sendAndClose(Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                    return false
                }

                let pending = handshakeBuffer.count > request.consumedBytes
                    ? Data(handshakeBuffer[request.consumedBytes...])
                    : Data()
                handshakeBuffer = Data()
                guard request.command == 0x01 else {
                    sendAndClose(Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                    return false
                }

                openRemoteStream(
                    host: request.host,
                    port: request.port,
                    successResponse: Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                    failureResponse: Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                    pendingPayload: pending
                )
                return false
            }
        }

        private func parseSocksRequest(from data: Data) throws -> SocksRequest? {
            let bytes = [UInt8](data)
            guard bytes.count >= 4 else { return nil }
            guard bytes[0] == 0x05 else {
                throw NSError(domain: "cmux.remote.proxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS version"])
            }

            let command = bytes[1]
            let addressType = bytes[3]
            var cursor = 4
            let host: String

            switch addressType {
            case 0x01:
                guard bytes.count >= cursor + 4 + 2 else { return nil }
                let octets = bytes[cursor..<(cursor + 4)].map { String($0) }
                host = octets.joined(separator: ".")
                cursor += 4

            case 0x03:
                guard bytes.count >= cursor + 1 else { return nil }
                let length = Int(bytes[cursor])
                cursor += 1
                guard bytes.count >= cursor + length + 2 else { return nil }
                let hostData = Data(bytes[cursor..<(cursor + length)])
                host = String(data: hostData, encoding: .utf8) ?? ""
                cursor += length

            case 0x04:
                guard bytes.count >= cursor + 16 + 2 else { return nil }
                var address = in6_addr()
                withUnsafeMutableBytes(of: &address) { target in
                    for i in 0..<16 {
                        target[i] = bytes[cursor + i]
                    }
                }
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                let pointer = withUnsafePointer(to: &address) {
                    inet_ntop(AF_INET6, UnsafeRawPointer($0), &text, socklen_t(INET6_ADDRSTRLEN))
                }
                host = pointer != nil ? String(cString: text) : ""
                cursor += 16

            default:
                throw NSError(domain: "cmux.remote.proxy", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS address type"])
            }

            guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "cmux.remote.proxy", code: 3, userInfo: [NSLocalizedDescriptionKey: "empty SOCKS host"])
            }
            guard bytes.count >= cursor + 2 else { return nil }
            let port = Int(UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1]))
            cursor += 2

            guard port > 0 && port <= 65535 else {
                throw NSError(domain: "cmux.remote.proxy", code: 4, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS port"])
            }

            return SocksRequest(host: host, port: port, command: command, consumedBytes: cursor)
        }

        private func processConnectHandshakeStep() -> Bool {
            let marker = Data([0x0D, 0x0A, 0x0D, 0x0A])
            guard let headerRange = handshakeBuffer.range(of: marker) else { return false }

            let headerData = Data(handshakeBuffer[..<headerRange.upperBound])
            let pending = headerRange.upperBound < handshakeBuffer.count
                ? Data(handshakeBuffer[headerRange.upperBound...])
                : Data()
            handshakeBuffer = Data()
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            let firstLine = headerText.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, parts[0].uppercased() == "CONNECT" else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            guard let (host, port) = Self.parseConnectAuthority(parts[1]) else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            openRemoteStream(
                host: host,
                port: port,
                successResponse: Self.httpResponse(status: "200 Connection Established", closeAfterResponse: false),
                failureResponse: Self.httpResponse(status: "502 Bad Gateway", closeAfterResponse: true),
                pendingPayload: pending
            )
            return false
        }

        private func openRemoteStream(
            host: String,
            port: Int,
            successResponse: Data,
            failureResponse: Data,
            pendingPayload: Data
        ) {
            guard !isClosed else { return }
            do {
                let targetHost = Self.normalizedProxyTargetHost(host)
                let streamID = try rpcClient.openStream(host: targetHost, port: port)
                self.streamID = streamID
                connection.send(content: successResponse, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.close(reason: "proxy client send error: \(error)")
                        return
                    }
                    if !pendingPayload.isEmpty {
                        self.forwardToRemote(pendingPayload, allowAfterEOF: true)
                    }
                    self.scheduleRemoteReadLoop()
                })
            } catch {
                sendAndClose(failureResponse)
            }
        }

        private func forwardToRemote(_ data: Data, allowAfterEOF: Bool = false) {
            guard !isClosed else { return }
            guard !localInputEOF || allowAfterEOF else { return }
            guard let streamID else { return }
            do {
                try rpcClient.writeStream(streamID: streamID, data: data)
            } catch {
                close(reason: "proxy.write failed: \(error.localizedDescription)")
            }
        }

        private func scheduleRemoteReadLoop() {
            guard let streamID else { return }
            readQueue.async { [weak self] in
                self?.pollRemoteOnce(streamID: streamID)
            }
        }

        private func pollRemoteOnce(streamID: String) {
            let readResult: Result<(data: Data, eof: Bool), Error>
            do {
                readResult = .success(try rpcClient.readStream(streamID: streamID, maxBytes: 32768, timeoutMs: 250))
            } catch {
                readResult = .failure(error)
            }

            queue.async { [weak self] in
                self?.handleRemoteReadResult(streamID: streamID, result: readResult)
            }
        }

        private func handleRemoteReadResult(streamID: String, result: Result<(data: Data, eof: Bool), Error>) {
            guard !isClosed else { return }
            guard self.streamID == streamID else { return }

            let readResult: (data: Data, eof: Bool)
            switch result {
            case .success(let value):
                readResult = value
            case .failure(let error):
                close(reason: "proxy.read failed: \(error.localizedDescription)")
                return
            }

            if !readResult.data.isEmpty {
                connection.send(content: readResult.data, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.close(reason: "proxy client send error: \(error)")
                        return
                    }
                    if readResult.eof {
                        self.close(reason: nil)
                    } else {
                        self.scheduleRemoteReadLoop()
                    }
                })
                return
            }

            if readResult.eof {
                close(reason: nil)
            } else {
                scheduleRemoteReadLoop()
            }
        }

        private func close(reason: String?) {
            guard !isClosed else { return }
            isClosed = true

            let streamID = self.streamID
            self.streamID = nil

            if let streamID {
                rpcClient.closeStream(streamID: streamID)
            }
            if reason != nil {
                connection.cancel()
            } else {
                connection.cancel()
            }
            onClose(id)
        }

        private func sendLocal(_ data: Data) {
            guard !isClosed else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.close(reason: "proxy client send error: \(error)")
                }
            })
        }

        private func sendAndClose(_ data: Data) {
            guard !isClosed else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.close(reason: nil)
            })
        }

        private static func parseConnectAuthority(_ authority: String) -> (host: String, port: Int)? {
            let trimmed = authority.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if trimmed.hasPrefix("[") {
                guard let closing = trimmed.firstIndex(of: "]") else { return nil }
                let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
                let portStart = trimmed.index(after: closing)
                guard portStart < trimmed.endIndex, trimmed[portStart] == ":" else { return nil }
                let portString = String(trimmed[trimmed.index(after: portStart)...])
                guard let port = Int(portString), port > 0, port <= 65535 else { return nil }
                return (host, port)
            }

            guard let colon = trimmed.lastIndex(of: ":") else { return nil }
            let host = String(trimmed[..<colon])
            let portString = String(trimmed[trimmed.index(after: colon)...])
            guard !host.isEmpty else { return nil }
            guard let port = Int(portString), port > 0, port <= 65535 else { return nil }
            return (host, port)
        }

        private static func normalizedProxyTargetHost(_ host: String) -> String {
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            // BrowserPanel rewrites loopback URLs to this alias so proxy routing works.
            // Resolve it back to true loopback before dialing from the remote daemon.
            if normalized == remoteLoopbackProxyAliasHost {
                return "127.0.0.1"
            }
            return host
        }

        private static func httpResponse(status: String, closeAfterResponse: Bool = true) -> Data {
            var text = "HTTP/1.1 \(status)\r\nProxy-Agent: cmux\r\n"
            if closeAfterResponse {
                text += "Connection: close\r\n"
            }
            text += "\r\n"
            return Data(text.utf8)
        }
    }

    private let configuration: WorkspaceRemoteConfiguration
    private let remotePath: String
    private let localPort: Int
    private let onFatalError: (String) -> Void
    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-tunnel.\(UUID().uuidString)", qos: .utility)

    private var listener: NWListener?
    private var rpcClient: WorkspaceRemoteDaemonRPCClient?
    private var sessions: [UUID: ProxySession] = [:]
    private var isStopped = false

    init(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        localPort: Int,
        onFatalError: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.remotePath = remotePath
        self.localPort = localPort
        self.onFatalError = onFatalError
    }

    func start() throws {
        var capturedError: Error?
        queue.sync {
            guard !isStopped else {
                capturedError = NSError(domain: "cmux.remote.proxy", code: 20, userInfo: [
                    NSLocalizedDescriptionKey: "proxy tunnel already stopped",
                ])
                return
            }
            do {
                let client = WorkspaceRemoteDaemonRPCClient(
                    configuration: configuration,
                    remotePath: remotePath
                ) { [weak self] detail in
                    self?.queue.async {
                        self?.failLocked("Remote daemon transport failed: \(detail)")
                    }
                }
                try client.start()

                let listener = try Self.makeLoopbackListener(port: localPort)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.queue.async {
                        self?.acceptConnectionLocked(connection)
                    }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    self?.queue.async {
                        self?.handleListenerStateLocked(state)
                    }
                }

                self.rpcClient = client
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                capturedError = error
                stopLocked(notify: false)
            }
        }
        if let capturedError {
            throw capturedError
        }
    }

    func stop() {
        queue.sync {
            stopLocked(notify: false)
        }
    }

    private func handleListenerStateLocked(_ state: NWListener.State) {
        guard !isStopped else { return }
        switch state {
        case .failed(let error):
            failLocked("Local proxy listener failed: \(error)")
        default:
            break
        }
    }

    private func acceptConnectionLocked(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }
        guard let rpcClient else {
            connection.cancel()
            return
        }

        let session = ProxySession(
            connection: connection,
            rpcClient: rpcClient,
            queue: queue
        ) { [weak self] id in
            self?.queue.async {
                self?.sessions.removeValue(forKey: id)
            }
        }
        sessions[session.id] = session
        session.start()
    }

    private func failLocked(_ detail: String) {
        guard !isStopped else { return }
        stopLocked(notify: false)
        onFatalError(detail)
    }

    private func stopLocked(notify: Bool) {
        guard !isStopped else { return }
        isStopped = true

        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        let activeSessions = sessions.values
        sessions.removeAll()
        for session in activeSessions {
            session.stop()
        }

        rpcClient?.stop()
        rpcClient = nil
    }

    private static func makeLoopbackListener(port: Int) throws -> NWListener {
        guard let localPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "cmux.remote.proxy", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "invalid local proxy port \(port)",
            ])
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: localPort)
        return try NWListener(using: parameters)
    }
}

private final class WorkspaceRemoteProxyBroker {
    enum Update {
        case connecting
        case ready(BrowserProxyEndpoint)
        case error(String)
    }

    final class Lease {
        private let key: String
        private let subscriberID: UUID
        private weak var broker: WorkspaceRemoteProxyBroker?
        private var isReleased = false

        fileprivate init(key: String, subscriberID: UUID, broker: WorkspaceRemoteProxyBroker) {
            self.key = key
            self.subscriberID = subscriberID
            self.broker = broker
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            broker?.release(key: key, subscriberID: subscriberID)
        }

        deinit {
            release()
        }
    }

    private final class Entry {
        let configuration: WorkspaceRemoteConfiguration
        var remotePath: String
        var tunnel: WorkspaceRemoteDaemonProxyTunnel?
        var endpoint: BrowserProxyEndpoint?
        var restartWorkItem: DispatchWorkItem?
        var subscribers: [UUID: (Update) -> Void] = [:]

        init(configuration: WorkspaceRemoteConfiguration, remotePath: String) {
            self.configuration = configuration
            self.remotePath = remotePath
        }
    }

    static let shared = WorkspaceRemoteProxyBroker()

    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.proxy-broker", qos: .utility)
    private var entries: [String: Entry] = [:]

    func acquire(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUpdate: @escaping (Update) -> Void
    ) -> Lease {
        queue.sync {
            let key = Self.transportKey(for: configuration)
            let subscriberID = UUID()
            let entry: Entry
            if let existing = entries[key] {
                entry = existing
                if existing.remotePath != remotePath {
                    existing.remotePath = remotePath
                    if existing.tunnel != nil {
                        stopEntryRuntimeLocked(existing)
                        notifyLocked(existing, update: .connecting)
                    }
                }
            } else {
                entry = Entry(configuration: configuration, remotePath: remotePath)
                entries[key] = entry
            }

            entry.subscribers[subscriberID] = onUpdate
            if let endpoint = entry.endpoint {
                onUpdate(.ready(endpoint))
            } else {
                onUpdate(.connecting)
            }

            if entry.tunnel == nil, entry.restartWorkItem == nil {
                startEntryLocked(key: key, entry: entry)
            }

            return Lease(key: key, subscriberID: subscriberID, broker: self)
        }
    }

    private func release(key: String, subscriberID: UUID) {
        queue.async { [weak self] in
            guard let self, let entry = self.entries[key] else { return }
            entry.subscribers.removeValue(forKey: subscriberID)
            guard entry.subscribers.isEmpty else { return }
            self.teardownEntryLocked(key: key, entry: entry)
        }
    }

    private func startEntryLocked(key: String, entry: Entry) {
        entry.restartWorkItem?.cancel()
        entry.restartWorkItem = nil

        let localPort: Int
        if let forcedLocalPort = entry.configuration.localProxyPort {
            // Internal deterministic test hook used by docker regressions to force bind conflicts.
            localPort = forcedLocalPort
        } else {
            guard let allocatedPort = Self.allocateLoopbackPort() else {
                notifyLocked(
                    entry,
                    update: .error("Failed to allocate local proxy port\(Self.retrySuffix(delay: 3.0))")
                )
                scheduleRestartLocked(key: key, entry: entry, delay: 3.0)
                return
            }
            localPort = allocatedPort
        }

        do {
            let tunnel = WorkspaceRemoteDaemonProxyTunnel(
                configuration: entry.configuration,
                remotePath: entry.remotePath,
                localPort: localPort
            ) { [weak self] detail in
                self?.queue.async {
                    self?.handleTunnelFailureLocked(key: key, detail: detail)
                }
            }
            try tunnel.start()
            entry.tunnel = tunnel
            let endpoint = BrowserProxyEndpoint(host: "127.0.0.1", port: localPort)
            entry.endpoint = endpoint
            notifyLocked(entry, update: .ready(endpoint))
        } catch {
            stopEntryRuntimeLocked(entry)
            let detail = "Failed to start local daemon proxy: \(error.localizedDescription)"
            notifyLocked(entry, update: .error("\(detail)\(Self.retrySuffix(delay: 3.0))"))
            scheduleRestartLocked(key: key, entry: entry, delay: 3.0)
        }
    }

    private func handleTunnelFailureLocked(key: String, detail: String) {
        guard let entry = entries[key], entry.tunnel != nil else { return }
        stopEntryRuntimeLocked(entry)
        notifyLocked(entry, update: .error("\(detail)\(Self.retrySuffix(delay: 3.0))"))
        scheduleRestartLocked(key: key, entry: entry, delay: 3.0)
    }

    private func scheduleRestartLocked(key: String, entry: Entry, delay: TimeInterval) {
        guard !entry.subscribers.isEmpty else {
            teardownEntryLocked(key: key, entry: entry)
            return
        }
        guard entry.restartWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let currentEntry = self.entries[key] else { return }
            currentEntry.restartWorkItem = nil
            guard !currentEntry.subscribers.isEmpty else {
                self.teardownEntryLocked(key: key, entry: currentEntry)
                return
            }
            self.notifyLocked(currentEntry, update: .connecting)
            self.startEntryLocked(key: key, entry: currentEntry)
        }

        entry.restartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func teardownEntryLocked(key: String, entry: Entry) {
        entry.restartWorkItem?.cancel()
        entry.restartWorkItem = nil
        stopEntryRuntimeLocked(entry)
        entries.removeValue(forKey: key)
    }

    private func stopEntryRuntimeLocked(_ entry: Entry) {
        entry.tunnel?.stop()
        entry.tunnel = nil
        entry.endpoint = nil
    }

    private func notifyLocked(_ entry: Entry, update: Update) {
        for callback in entry.subscribers.values {
            callback(update)
        }
    }

    private static func transportKey(for configuration: WorkspaceRemoteConfiguration) -> String {
        let destination = configuration.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = configuration.port.map(String.init) ?? ""
        let identity = configuration.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let localProxyPort = configuration.localProxyPort.map(String.init) ?? ""
        let options = configuration.sshOptions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\u{1f}")
        return [destination, port, identity, options, localProxyPort].joined(separator: "\u{1e}")
    }

    private static func allocateLoopbackPort() -> Int? {
        for _ in 0..<8 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(0)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { continue }

            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    getsockname(fd, sockaddrPtr, &len)
                }
            }
            guard nameResult == 0 else { continue }

            let port = Int(UInt16(bigEndian: bound.sin_port))
            if port > 0 && port <= 65535 {
                return port
            }
        }
        return nil
    }

    private static func retrySuffix(delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return " (retry in \(seconds)s)"
    }
}

private final class WorkspaceRemoteSessionController {
    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private struct RemotePlatform {
        let goOS: String
        let goArch: String
    }

    private struct DaemonHello {
        let name: String
        let version: String
        let capabilities: [String]
        let remotePath: String
    }

    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.\(UUID().uuidString)", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private weak var workspace: Workspace?
    private let configuration: WorkspaceRemoteConfiguration
    private let controllerID: UUID

    private var isStopping = false
    private var proxyLease: WorkspaceRemoteProxyBroker.Lease?
    private var proxyEndpoint: BrowserProxyEndpoint?
    private var daemonReady = false
    private var daemonBootstrapVersion: String?
    private var daemonRemotePath: String?
    private var reconnectRetryCount = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var heartbeatWorkItem: DispatchWorkItem?
    private var heartbeatCount: Int = 0

    private static let heartbeatInterval: TimeInterval = 3.0

    init(workspace: Workspace, configuration: WorkspaceRemoteConfiguration, controllerID: UUID) {
        self.workspace = workspace
        self.configuration = configuration
        self.controllerID = controllerID
        queue.setSpecific(key: queueKey, value: ())
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isStopping else { return }
            self.beginConnectionAttemptLocked()
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopAllLocked()
            return
        }
        queue.async { [self] in
            stopAllLocked()
        }
    }

    private func stopAllLocked() {
        isStopping = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectRetryCount = 0
        stopHeartbeatLocked(reset: true)

        proxyLease?.release()
        proxyLease = nil
        proxyEndpoint = nil
        daemonReady = false
        daemonBootstrapVersion = nil
        daemonRemotePath = nil
        publishProxyEndpoint(nil)
        publishPortsSnapshotLocked()
    }

    private func beginConnectionAttemptLocked() {
        guard !isStopping else { return }

        reconnectWorkItem = nil
        stopHeartbeatLocked(reset: true)
        let connectDetail: String
        let bootstrapDetail: String
        if reconnectRetryCount > 0 {
            connectDetail = "Reconnecting to \(configuration.displayTarget) (retry \(reconnectRetryCount))"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget) (retry \(reconnectRetryCount))"
        } else {
            connectDetail = "Connecting to \(configuration.displayTarget)"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget)"
        }
        publishState(.connecting, detail: connectDetail)
        publishDaemonStatus(.bootstrapping, detail: bootstrapDetail)
        do {
            let hello = try bootstrapDaemonLocked()
            guard hello.capabilities.contains("proxy.stream") else {
                throw NSError(domain: "cmux.remote.daemon", code: 43, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon missing required capability proxy.stream",
                ])
            }
            daemonReady = true
            daemonBootstrapVersion = hello.version
            daemonRemotePath = hello.remotePath
            publishDaemonStatus(
                .ready,
                detail: "Remote daemon ready",
                version: hello.version,
                name: hello.name,
                capabilities: hello.capabilities,
                remotePath: hello.remotePath
            )
            startProxyLocked()
        } catch {
            daemonReady = false
            daemonBootstrapVersion = nil
            daemonRemotePath = nil
            let nextRetry = scheduleReconnectLocked(delay: 4.0)
            let retrySuffix = Self.retrySuffix(retry: nextRetry, delay: 4.0)
            let detail = "Remote daemon bootstrap failed: \(error.localizedDescription)\(retrySuffix)"
            publishDaemonStatus(.error, detail: detail)
            publishState(.error, detail: detail)
        }
    }

    private func startProxyLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard proxyLease == nil else { return }
        guard let remotePath = daemonRemotePath,
              !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let nextRetry = scheduleReconnectLocked(delay: 4.0)
            let retrySuffix = Self.retrySuffix(retry: nextRetry, delay: 4.0)
            let detail = "Remote daemon did not provide a valid remote path\(retrySuffix)"
            publishDaemonStatus(.error, detail: detail)
            publishState(.error, detail: detail)
            return
        }

        let lease = WorkspaceRemoteProxyBroker.shared.acquire(
            configuration: configuration,
            remotePath: remotePath
        ) { [weak self] update in
            self?.queue.async {
                self?.handleProxyBrokerUpdateLocked(update)
            }
        }
        proxyLease = lease
    }

    private func handleProxyBrokerUpdateLocked(_ update: WorkspaceRemoteProxyBroker.Update) {
        guard !isStopping else { return }
        switch update {
        case .connecting:
            if proxyEndpoint == nil {
                publishState(.connecting, detail: "Connecting to \(configuration.displayTarget)")
            }
        case .ready(let endpoint):
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            reconnectRetryCount = 0
            guard proxyEndpoint != endpoint else {
                startHeartbeatLocked()
                return
            }
            proxyEndpoint = endpoint
            publishProxyEndpoint(endpoint)
            publishPortsSnapshotLocked()
            publishState(
                .connected,
                detail: "Connected to \(configuration.displayTarget) via shared local proxy \(endpoint.host):\(endpoint.port)"
            )
            startHeartbeatLocked()
        case .error(let detail):
            proxyEndpoint = nil
            stopHeartbeatLocked(reset: false)
            publishProxyEndpoint(nil)
            publishPortsSnapshotLocked()
            publishState(.error, detail: "Remote proxy to \(configuration.displayTarget) unavailable: \(detail)")
            guard Self.shouldEscalateProxyErrorToBootstrap(detail) else { return }

            proxyLease?.release()
            proxyLease = nil
            daemonReady = false
            daemonBootstrapVersion = nil
            daemonRemotePath = nil

            let nextRetry = scheduleReconnectLocked(delay: 2.0)
            let retrySuffix = Self.retrySuffix(retry: nextRetry, delay: 2.0)
            publishDaemonStatus(
                .error,
                detail: "Remote daemon transport needs re-bootstrap after proxy failure\(retrySuffix)"
            )
        }
    }

    @discardableResult
    private func scheduleReconnectLocked(delay: TimeInterval) -> Int {
        guard !isStopping else { return reconnectRetryCount }
        reconnectWorkItem?.cancel()
        reconnectRetryCount += 1
        let retryNumber = reconnectRetryCount
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            guard !self.isStopping else { return }
            guard self.proxyLease == nil else { return }
            self.beginConnectionAttemptLocked()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        return retryNumber
    }

    private func publishState(_ state: WorkspaceRemoteConnectionState, detail: String?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteConnectionStateUpdate(
                state,
                detail: detail,
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    private func publishDaemonStatus(
        _ state: WorkspaceRemoteDaemonState,
        detail: String?,
        version: String? = nil,
        name: String? = nil,
        capabilities: [String] = [],
        remotePath: String? = nil
    ) {
        let controllerID = self.controllerID
        let status = WorkspaceRemoteDaemonStatus(
            state: state,
            detail: detail,
            version: version,
            name: name,
            capabilities: capabilities,
            remotePath: remotePath
        )
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteDaemonStatusUpdate(
                status,
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    private func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteProxyEndpointUpdate(endpoint)
        }
    }

    private func publishPortsSnapshotLocked() {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemotePortsSnapshot(
                detected: [],
                forwarded: [],
                conflicts: [],
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    private func startHeartbeatLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard proxyLease != nil else { return }
        guard heartbeatWorkItem == nil else { return }

        heartbeatCount += 1
        publishHeartbeat(count: heartbeatCount, at: Date())
        scheduleNextHeartbeatLocked()
    }

    private func scheduleNextHeartbeatLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard proxyLease != nil else { return }

        heartbeatWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.heartbeatWorkItem = nil
            guard !self.isStopping else { return }
            guard self.daemonReady else { return }
            guard self.proxyLease != nil else { return }
            self.heartbeatCount += 1
            self.publishHeartbeat(count: self.heartbeatCount, at: Date())
            self.scheduleNextHeartbeatLocked()
        }
        heartbeatWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.heartbeatInterval, execute: workItem)
    }

    private func stopHeartbeatLocked(reset: Bool) {
        heartbeatWorkItem?.cancel()
        heartbeatWorkItem = nil
        if reset {
            heartbeatCount = 0
            publishHeartbeat(count: 0, at: nil)
        }
    }

    private func publishHeartbeat(count: Int, at date: Date?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteHeartbeatUpdate(count: count, lastSeenAt: date)
        }
    }

    private func sshCommonArguments(batchMode: Bool) -> [String] {
        let effectiveSSHOptions: [String] = {
            if batchMode {
                return backgroundSSHOptions(configuration.sshOptions)
            }
            return normalizedSSHOptions(configuration.sshOptions)
        }()
        var args: [String] = [
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
        ]
        if !hasSSHOptionKey(effectiveSSHOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        if batchMode {
            args += ["-o", "BatchMode=yes"]
            // Avoid shared ControlPath lock contention with interactive ssh sessions.
            args += ["-o", "ControlMaster=no"]
        }
        if let port = configuration.port {
            args += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }
        return args
    }

    private func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        for option in options {
            let token = sshOptionKey(option)
            if token == loweredKey {
                return true
            }
        }
        return false
    }

    private func normalizedSSHOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }
    }

    private func backgroundSSHOptions(_ options: [String]) -> [String] {
        let sharingKeys: Set<String> = [
            "controlmaster",
            "controlpersist",
            "controlpath",
        ]
        return normalizedSSHOptions(options).filter { option in
            guard let key = sshOptionKey(option) else { return false }
            return !sharingKeys.contains(key)
        }
    }

    private func sshOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    private func sshExec(arguments: [String], stdin: Data? = nil, timeout: TimeInterval = 15) throws -> CommandResult {
        try runProcess(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            stdin: stdin,
            timeout: timeout
        )
    }

    private func scpExec(arguments: [String], timeout: TimeInterval = 30) throws -> CommandResult {
        try runProcess(
            executable: "/usr/bin/scp",
            arguments: arguments,
            stdin: nil,
            timeout: timeout
        )
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdin: Data?,
        timeout: TimeInterval
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if stdin != nil {
            process.standardInput = Pipe()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            throw NSError(domain: "cmux.remote.process", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)",
            ])
        }

        if let stdin, let pipe = process.standardInput as? Pipe {
            pipe.fileHandleForWriting.write(stdin)
            try? pipe.fileHandleForWriting.close()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let terminateDeadline = Date().addingTimeInterval(2.0)
            while process.isRunning && Date() < terminateDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw NSError(domain: "cmux.remote.process", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executable).lastPathComponent) timed out after \(Int(timeout))s",
            ])
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func bootstrapDaemonLocked() throws -> DaemonHello {
        let platform = try resolveRemotePlatformLocked()
        let version = Self.remoteDaemonVersion()
        let remotePath = Self.remoteDaemonPath(version: version, goOS: platform.goOS, goArch: platform.goArch)

        let hadExistingBinary = try remoteDaemonExistsLocked(remotePath: remotePath)
        if !hadExistingBinary {
            let localBinary = try buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
        }

        var hello = try helloRemoteDaemonLocked(remotePath: remotePath)
        if hadExistingBinary, !hello.capabilities.contains("proxy.stream") {
            let localBinary = try buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
            hello = try helloRemoteDaemonLocked(remotePath: remotePath)
        }

        return hello
    }

    private func resolveRemotePlatformLocked() throws -> RemotePlatform {
        let script = "uname -s; uname -m"
        let command = "sh -c \(Self.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 20)
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "failed to query remote platform: \(detail)",
            ])
        }

        let lines = result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else {
            throw NSError(domain: "cmux.remote.daemon", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "remote platform probe returned invalid output",
            ])
        }

        guard let goOS = Self.mapUnameOS(lines[0]),
              let goArch = Self.mapUnameArch(lines[1]) else {
            throw NSError(domain: "cmux.remote.daemon", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "unsupported remote platform \(lines[0])/\(lines[1])",
            ])
        }

        return RemotePlatform(goOS: goOS, goArch: goArch)
    }

    private func remoteDaemonExistsLocked(remotePath: String) throws -> Bool {
        let script = "if [ -x \(Self.shellSingleQuoted(remotePath)) ]; then echo yes; else echo no; fi"
        let command = "sh -c \(Self.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 8)
        guard result.status == 0 else { return false }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
    }

    private func buildLocalDaemonBinary(goOS: String, goArch: String, version: String) throws -> URL {
        if let bundledBinary = Self.findBundledDaemonBinary(goOS: goOS, goArch: goArch, version: version) {
            return bundledBinary
        }

        guard let repoRoot = Self.findRepoRoot() else {
            throw NSError(domain: "cmux.remote.daemon", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "cannot locate cmux repo root for daemon build and no bundled cmuxd-remote binary was found",
            ])
        }
        let daemonRoot = repoRoot.appendingPathComponent("daemon/remote", isDirectory: true)
        let goModPath = daemonRoot.appendingPathComponent("go.mod").path
        guard FileManager.default.fileExists(atPath: goModPath) else {
            throw NSError(domain: "cmux.remote.daemon", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "missing daemon module at \(goModPath)",
            ])
        }
        guard let goBinary = Self.which("go") else {
            throw NSError(domain: "cmux.remote.daemon", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "go is required to build cmuxd-remote when no bundled binary is available",
            ])
        }

        let cacheRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-remote-daemon-build", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let output = cacheRoot.appendingPathComponent("cmuxd-remote", isDirectory: false)

        var env = ProcessInfo.processInfo.environment
        env["GOOS"] = goOS
        env["GOARCH"] = goArch
        env["CGO_ENABLED"] = "0"
        let ldflags = "-s -w -X main.version=\(version)"
        let result = try runProcess(
            executable: goBinary,
            arguments: ["build", "-trimpath", "-ldflags", ldflags, "-o", output.path, "./cmd/cmuxd-remote"],
            environment: env,
            currentDirectory: daemonRoot,
            stdin: nil,
            timeout: 90
        )
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "go build failed with status \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "failed to build cmuxd-remote: \(detail)",
            ])
        }
        guard FileManager.default.isExecutableFile(atPath: output.path) else {
            throw NSError(domain: "cmux.remote.daemon", code: 24, userInfo: [
                NSLocalizedDescriptionKey: "cmuxd-remote build output is not executable",
            ])
        }
        return output
    }

    private static func findBundledDaemonBinary(goOS: String, goArch: String, version: String) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["CMUX_REMOTE_DAEMON_BINARY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            candidates.append(URL(fileURLWithPath: explicit, isDirectory: false))
        }
        if let resourceRoot = Bundle.main.resourceURL {
            candidates.append(resourceRoot.appendingPathComponent("bin/cmuxd-remote-\(goOS)-\(goArch)", isDirectory: false))
            candidates.append(resourceRoot.appendingPathComponent("bin/cmuxd-remote", isDirectory: false))
            candidates.append(resourceRoot.appendingPathComponent("cmuxd-remote/\(goOS)-\(goArch)/cmuxd-remote", isDirectory: false))
            candidates.append(resourceRoot.appendingPathComponent("cmuxd-remote/\(version)/\(goOS)-\(goArch)/cmuxd-remote", isDirectory: false))
        }

        for candidate in candidates.map(\.standardizedFileURL) where fm.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    private func uploadRemoteDaemonBinaryLocked(localBinary: URL, remotePath: String) throws {
        let remoteDirectory = (remotePath as NSString).deletingLastPathComponent
        let remoteTempPath = "\(remotePath).tmp-\(UUID().uuidString.prefix(8))"

        let mkdirScript = "mkdir -p \(Self.shellSingleQuoted(remoteDirectory))"
        let mkdirCommand = "sh -c \(Self.shellSingleQuoted(mkdirScript))"
        let mkdirResult = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, mkdirCommand], timeout: 12)
        guard mkdirResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: mkdirResult.stderr, stdout: mkdirResult.stdout) ?? "ssh exited \(mkdirResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "failed to create remote daemon directory: \(detail)",
            ])
        }

        let scpSSHOptions = backgroundSSHOptions(configuration.sshOptions)
        var scpArgs: [String] = ["-q"]
        if !hasSSHOptionKey(scpSSHOptions, key: "StrictHostKeyChecking") {
            scpArgs += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        // Keep bootstrap SCP detached from shared interactive ssh control sockets.
        scpArgs += ["-o", "ControlMaster=no"]
        if let port = configuration.port {
            scpArgs += ["-P", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scpArgs += ["-i", identityFile]
        }
        for option in scpSSHOptions {
            scpArgs += ["-o", option]
        }
        scpArgs += [localBinary.path, "\(configuration.destination):\(remoteTempPath)"]
        let scpResult = try scpExec(arguments: scpArgs, timeout: 45)
        guard scpResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: scpResult.stderr, stdout: scpResult.stdout) ?? "scp exited \(scpResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "failed to upload cmuxd-remote: \(detail)",
            ])
        }

        let finalizeScript = """
        chmod 755 \(Self.shellSingleQuoted(remoteTempPath)) && \
        mv \(Self.shellSingleQuoted(remoteTempPath)) \(Self.shellSingleQuoted(remotePath))
        """
        let finalizeCommand = "sh -c \(Self.shellSingleQuoted(finalizeScript))"
        let finalizeResult = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, finalizeCommand], timeout: 12)
        guard finalizeResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: finalizeResult.stderr, stdout: finalizeResult.stdout) ?? "ssh exited \(finalizeResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "failed to install remote daemon binary: \(detail)",
            ])
        }
    }

    private func helloRemoteDaemonLocked(remotePath: String) throws -> DaemonHello {
        let request = #"{"id":1,"method":"hello","params":{}}"#
        let script = "printf '%s\\n' \(Self.shellSingleQuoted(request)) | \(Self.shellSingleQuoted(remotePath)) serve --stdio"
        let command = "sh -c \(Self.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 12)
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 40, userInfo: [
                NSLocalizedDescriptionKey: "failed to start remote daemon: \(detail)",
            ])
        }

        let responseLine = result.stdout
            .split(separator: "\n")
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
        guard !responseLine.isEmpty,
              let data = responseLine.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw NSError(domain: "cmux.remote.daemon", code: 41, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello returned invalid JSON",
            ])
        }

        if let ok = payload["ok"] as? Bool, !ok {
            let errorMessage: String = {
                if let errorObject = payload["error"] as? [String: Any],
                   let message = errorObject["message"] as? String,
                   !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }
                return "hello call failed"
            }()
            throw NSError(domain: "cmux.remote.daemon", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello failed: \(errorMessage)",
            ])
        }

        let resultObject = payload["result"] as? [String: Any] ?? [:]
        let name = (resultObject["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (resultObject["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let capabilities = (resultObject["capabilities"] as? [String]) ?? []
        return DaemonHello(
            name: (name?.isEmpty == false ? name! : "cmuxd-remote"),
            version: (version?.isEmpty == false ? version! : "dev"),
            capabilities: capabilities,
            remotePath: remotePath
        )
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func mapUnameOS(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "linux":
            return "linux"
        case "darwin":
            return "darwin"
        case "freebsd":
            return "freebsd"
        default:
            return nil
        }
    }

    private static func mapUnameArch(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "x86_64", "amd64":
            return "amd64"
        case "aarch64", "arm64":
            return "arm64"
        case "armv7l":
            return "arm"
        default:
            return nil
        }
    }

    private static func remoteDaemonVersion() -> String {
        let bundleVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let bundleVersion, !bundleVersion.isEmpty {
            return bundleVersion
        }
        return "dev"
    }

    private static func remoteDaemonPath(version: String, goOS: String, goArch: String) -> String {
        ".cmux/bin/cmuxd-remote/\(version)/\(goOS)-\(goArch)/cmuxd-remote"
    }

    private static func which(_ executable: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for component in path.split(separator: ":") {
            let candidate = String(component) + "/" + executable
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func findRepoRoot() -> URL? {
        var candidates: [URL] = []
        let compileTimeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
        candidates.append(compileTimeRoot)
        let environment = ProcessInfo.processInfo.environment
        if let envRoot = environment["CMUX_REMOTE_DAEMON_SOURCE_ROOT"],
           !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
        }
        if let envRoot = environment["CMUXTERM_REPO_ROOT"],
           !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executable)
            candidates.append(executable.deletingLastPathComponent())
            candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent())
        }

        let fm = FileManager.default
        for base in candidates {
            var cursor = base.standardizedFileURL
            for _ in 0..<10 {
                let marker = cursor.appendingPathComponent("daemon/remote/go.mod").path
                if fm.fileExists(atPath: marker) {
                    return cursor
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path {
                    break
                }
                cursor = parent
            }
        }
        return nil
    }

    private static func bestErrorLine(stderr: String, stdout: String = "") -> String? {
        if let stderrLine = meaningfulErrorLine(in: stderr) {
            return stderrLine
        }
        if let stdoutLine = meaningfulErrorLine(in: stdout) {
            return stdoutLine
        }
        return nil
    }

    private static func meaningfulErrorLine(in text: String) -> String? {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() where !isNoiseLine(line) {
            return line
        }
        return lines.last
    }

    private static func isNoiseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("warning: permanently added") { return true }
        if lowered.hasPrefix("debug") { return true }
        if lowered.hasPrefix("transferred:") { return true }
        if lowered.hasPrefix("openbsd_") { return true }
        if lowered.contains("pseudo-terminal will not be allocated") { return true }
        return false
    }

    private static func retrySuffix(retry: Int, delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return " (retry \(retry) in \(seconds)s)"
    }

    private static func shouldEscalateProxyErrorToBootstrap(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("remote daemon transport failed")
            || lowered.contains("daemon transport closed stdout")
            || lowered.contains("daemon transport exited")
            || lowered.contains("daemon transport is not connected")
            || lowered.contains("daemon transport stopped")
    }

}

enum SidebarLogLevel: String {
    case info
    case progress
    case success
    case warning
    case error
}

struct SidebarLogEntry {
    let message: String
    let level: SidebarLogLevel
    let source: String?
    let timestamp: Date
}

struct SidebarProgressState {
    let value: Double
    let label: String?
}

struct SidebarGitBranchState {
    let branch: String
    let isDirty: Bool
}

enum WorkspaceRemoteConnectionState: String {
    case disconnected
    case connecting
    case connected
    case error
}

enum WorkspaceRemoteDaemonState: String {
    case unavailable
    case bootstrapping
    case ready
    case error
}

struct WorkspaceRemoteDaemonStatus: Equatable {
    var state: WorkspaceRemoteDaemonState = .unavailable
    var detail: String?
    var version: String?
    var name: String?
    var capabilities: [String] = []
    var remotePath: String?

    func payload() -> [String: Any] {
        [
            "state": state.rawValue,
            "detail": detail ?? NSNull(),
            "version": version ?? NSNull(),
            "name": name ?? NSNull(),
            "capabilities": capabilities,
            "remote_path": remotePath ?? NSNull(),
        ]
    }
}

struct WorkspaceRemoteConfiguration: Equatable {
    let destination: String
    let port: Int?
    let identityFile: String?
    let sshOptions: [String]
    let localProxyPort: Int?

    var displayTarget: String {
        guard let port else { return destination }
        return "\(destination):\(port)"
    }
}

enum SidebarPullRequestStatus: String {
    case open
    case merged
    case closed
}

struct SidebarPullRequestState: Equatable {
    let number: Int
    let label: String
    let url: URL
    let status: SidebarPullRequestStatus
}

enum SidebarBranchOrdering {
    struct BranchEntry: Equatable {
        let name: String
        let isDirty: Bool
    }

    struct BranchDirectoryEntry: Equatable {
        let branch: String?
        let isDirty: Bool
        let directory: String?
    }

    static func orderedPaneIds(tree: ExternalTreeNode) -> [String] {
        switch tree {
        case .pane(let pane):
            return [pane.id]
        case .split(let split):
            // Bonsplit split order matches visual order for both horizontal and vertical splits.
            return orderedPaneIds(tree: split.first) + orderedPaneIds(tree: split.second)
        }
    }

    static func orderedPanelIds(
        tree: ExternalTreeNode,
        paneTabs: [String: [UUID]],
        fallbackPanelIds: [UUID]
    ) -> [UUID] {
        var ordered: [UUID] = []
        var seen: Set<UUID> = []

        for paneId in orderedPaneIds(tree: tree) {
            for panelId in paneTabs[paneId] ?? [] {
                if seen.insert(panelId).inserted {
                    ordered.append(panelId)
                }
            }
        }

        for panelId in fallbackPanelIds {
            if seen.insert(panelId).inserted {
                ordered.append(panelId)
            }
        }

        return ordered
    }

    static func orderedUniqueBranches(
        orderedPanelIds: [UUID],
        panelBranches: [UUID: SidebarGitBranchState],
        fallbackBranch: SidebarGitBranchState?
    ) -> [BranchEntry] {
        var orderedNames: [String] = []
        var branchDirty: [String: Bool] = [:]

        for panelId in orderedPanelIds {
            guard let state = panelBranches[panelId] else { continue }
            let name = state.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            if branchDirty[name] == nil {
                orderedNames.append(name)
                branchDirty[name] = state.isDirty
            } else if state.isDirty {
                branchDirty[name] = true
            }
        }

        if orderedNames.isEmpty, let fallbackBranch {
            let name = fallbackBranch.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return [BranchEntry(name: name, isDirty: fallbackBranch.isDirty)]
            }
        }

        return orderedNames.map { name in
            BranchEntry(name: name, isDirty: branchDirty[name] ?? false)
        }
    }

    static func orderedUniquePullRequests(
        orderedPanelIds: [UUID],
        panelPullRequests: [UUID: SidebarPullRequestState],
        fallbackPullRequest: SidebarPullRequestState?
    ) -> [SidebarPullRequestState] {
        func statusPriority(_ status: SidebarPullRequestStatus) -> Int {
            switch status {
            case .merged: return 3
            case .open: return 2
            case .closed: return 1
            }
        }

        func normalizedReviewURLKey(for url: URL) -> String {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url.absoluteString
            }

            // Treat URL variants that differ only by query/fragment as the same review item.
            components.query = nil
            components.fragment = nil
            let scheme = components.scheme?.lowercased() ?? ""
            let host = components.host?.lowercased() ?? ""
            let port = components.port.map { ":\($0)" } ?? ""
            var path = components.path
            if path.hasSuffix("/"), path.count > 1 {
                path.removeLast()
            }
            return "\(scheme)://\(host)\(port)\(path)"
        }

        func reviewKey(for state: SidebarPullRequestState) -> String {
            "\(state.label.lowercased())#\(state.number)|\(normalizedReviewURLKey(for: state.url))"
        }

        var orderedKeys: [String] = []
        var pullRequestsByKey: [String: SidebarPullRequestState] = [:]

        for panelId in orderedPanelIds {
            guard let state = panelPullRequests[panelId] else { continue }
            let key = reviewKey(for: state)
            if pullRequestsByKey[key] == nil {
                orderedKeys.append(key)
                pullRequestsByKey[key] = state
                continue
            }
            guard let existing = pullRequestsByKey[key] else { continue }
            if statusPriority(state.status) > statusPriority(existing.status) {
                pullRequestsByKey[key] = state
            }
        }

        if orderedKeys.isEmpty, let fallbackPullRequest {
            return [fallbackPullRequest]
        }

        return orderedKeys.compactMap { pullRequestsByKey[$0] }
    }

    static func orderedUniqueBranchDirectoryEntries(
        orderedPanelIds: [UUID],
        panelBranches: [UUID: SidebarGitBranchState],
        panelDirectories: [UUID: String],
        defaultDirectory: String?,
        fallbackBranch: SidebarGitBranchState?
    ) -> [BranchDirectoryEntry] {
        struct EntryKey: Hashable {
            let directory: String?
            let branch: String?
        }

        struct MutableEntry {
            var branch: String?
            var isDirty: Bool
            var directory: String?
        }

        func normalized(_ text: String?) -> String? {
            guard let text else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        func canonicalDirectoryKey(_ directory: String?) -> String? {
            guard let directory = normalized(directory) else { return nil }
            let expanded = NSString(string: directory).expandingTildeInPath
            let standardized = NSString(string: expanded).standardizingPath
            let cleaned = standardized.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }

        let normalizedFallbackBranch = normalized(fallbackBranch?.branch)
        let shouldUseFallbackBranchPerPanel = !orderedPanelIds.contains {
            normalized(panelBranches[$0]?.branch) != nil
        }
        let defaultBranchForPanels = shouldUseFallbackBranchPerPanel ? normalizedFallbackBranch : nil
        let defaultBranchDirty = shouldUseFallbackBranchPerPanel ? (fallbackBranch?.isDirty ?? false) : false

        var order: [EntryKey] = []
        var entries: [EntryKey: MutableEntry] = [:]

        for panelId in orderedPanelIds {
            let panelBranch = normalized(panelBranches[panelId]?.branch)
            let branch = panelBranch ?? defaultBranchForPanels
            let directory = normalized(panelDirectories[panelId] ?? defaultDirectory)
            guard branch != nil || directory != nil else { continue }

            let panelDirty = panelBranch != nil
                ? (panelBranches[panelId]?.isDirty ?? false)
                : defaultBranchDirty

            let key: EntryKey
            if let directoryKey = canonicalDirectoryKey(directory) {
                // Keep one line per directory and allow the latest branch state to overwrite.
                key = EntryKey(directory: directoryKey, branch: nil)
            } else {
                key = EntryKey(directory: nil, branch: branch)
            }

            guard key.directory != nil || key.branch != nil else { continue }

            if var existing = entries[key] {
                if key.directory != nil {
                    if let branch {
                        existing.branch = branch
                        existing.isDirty = panelDirty
                    } else if existing.branch == nil {
                        existing.isDirty = panelDirty
                    }
                    if let directory {
                        existing.directory = directory
                    }
                    entries[key] = existing
                } else if panelDirty {
                    existing.isDirty = true
                    entries[key] = existing
                }
            } else {
                order.append(key)
                entries[key] = MutableEntry(branch: branch, isDirty: panelDirty, directory: directory)
            }
        }

        if order.isEmpty {
            let fallbackDirectory = normalized(defaultDirectory)
            if normalizedFallbackBranch != nil || fallbackDirectory != nil {
                return [
                    BranchDirectoryEntry(
                        branch: normalizedFallbackBranch,
                        isDirty: fallbackBranch?.isDirty ?? false,
                        directory: fallbackDirectory
                    )
                ]
            }
        }

        return order.compactMap { key in
            guard let entry = entries[key] else { return nil }
            return BranchDirectoryEntry(
                branch: entry.branch,
                isDirty: entry.isDirty,
                directory: entry.directory
            )
        }
    }
}

struct ClosedBrowserPanelRestoreSnapshot {
    let workspaceId: UUID
    let url: URL?
    let originalPaneId: UUID
    let originalTabIndex: Int
    let fallbackSplitOrientation: SplitOrientation?
    let fallbackSplitInsertFirst: Bool
    let fallbackAnchorPaneId: UUID?
}

/// Workspace represents a sidebar tab.
/// Each workspace contains one BonsplitController that manages split panes and nested surfaces.
@MainActor
final class Workspace: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    @Published var customTitle: String?
    @Published var isPinned: Bool = false
    @Published var customColor: String?  // hex string, e.g. "#C0392B"
    @Published var currentDirectory: String

    /// Ordinal for CMUX_PORT range assignment (monotonically increasing per app session)
    var portOrdinal: Int = 0

    /// The bonsplit controller managing the split panes for this workspace
    let bonsplitController: BonsplitController

    /// Mapping from bonsplit TabID to our Panel instances
    @Published private(set) var panels: [UUID: any Panel] = [:]

    /// Subscriptions for panel updates (e.g., browser title changes)
    private var panelSubscriptions: [UUID: AnyCancellable] = [:]

    /// When true, suppresses auto-creation in didSplitPane (programmatic splits handle their own panels)
    private var isProgrammaticSplit = false

    /// Last terminal panel used as an inheritance source (typically last focused terminal).
    private var lastTerminalConfigInheritancePanelId: UUID?
    /// Last known terminal font points from inheritance sources. Used as fallback when
    /// no live terminal surface is currently available.
    private var lastTerminalConfigInheritanceFontPoints: Float?
    /// Per-panel inherited zoom lineage. Descendants reuse this root value unless
    /// a panel is explicitly re-zoomed by the user.
    private var terminalInheritanceFontPointsByPanelId: [UUID: Float] = [:]

    /// Callback used by TabManager to capture recently closed browser panels for Cmd+Shift+T restore.
    var onClosedBrowserPanel: ((ClosedBrowserPanelRestoreSnapshot) -> Void)?


    // Closing tabs mutates split layout immediately; terminal views handle their own AppKit
    // layout/size synchronization.

    /// The currently focused pane's panel ID
    var focusedPanelId: UUID? {
        guard let paneId = bonsplitController.focusedPaneId,
              let tab = bonsplitController.selectedTab(inPane: paneId) else {
            return nil
        }
        return panelIdFromSurfaceId(tab.id)
    }

    /// The currently focused terminal panel (if any)
    var focusedTerminalPanel: TerminalPanel? {
        guard let panelId = focusedPanelId,
              let panel = panels[panelId] as? TerminalPanel else {
            return nil
        }
        return panel
    }

    /// Published directory for each panel
    @Published var panelDirectories: [UUID: String] = [:]
    @Published var panelTitles: [UUID: String] = [:]
    @Published private(set) var panelCustomTitles: [UUID: String] = [:]
    @Published private(set) var pinnedPanelIds: Set<UUID> = []
    @Published private(set) var manualUnreadPanelIds: Set<UUID> = []
    @Published var panelGitBranches: [UUID: SidebarGitBranchState] = [:]
    @Published var statusEntries: [String: SidebarStatusEntry] = [:]
    @Published var metadataBlocks: [String: SidebarMetadataBlock] = [:]
    @Published var logEntries: [SidebarLogEntry] = []
    @Published var progress: SidebarProgressState?
    @Published var gitBranch: SidebarGitBranchState?
    @Published var pullRequest: SidebarPullRequestState?
    @Published var panelPullRequests: [UUID: SidebarPullRequestState] = [:]
    @Published var surfaceListeningPorts: [UUID: [Int]] = [:]
    @Published var remoteConfiguration: WorkspaceRemoteConfiguration?
    @Published var remoteConnectionState: WorkspaceRemoteConnectionState = .disconnected
    @Published var remoteConnectionDetail: String?
    @Published var remoteDaemonStatus: WorkspaceRemoteDaemonStatus = WorkspaceRemoteDaemonStatus()
    @Published var remoteDetectedPorts: [Int] = []
    @Published var remoteForwardedPorts: [Int] = []
    @Published var remotePortConflicts: [Int] = []
    @Published var remoteProxyEndpoint: BrowserProxyEndpoint?
    @Published var remoteHeartbeatCount: Int = 0
    @Published var remoteLastHeartbeatAt: Date?
    @Published var listeningPorts: [Int] = []
    var surfaceTTYNames: [UUID: String] = [:]
    private var remoteSessionController: WorkspaceRemoteSessionController?
    fileprivate var activeRemoteSessionControllerID: UUID?
    private var remoteLastErrorFingerprint: String?
    private var remoteLastDaemonErrorFingerprint: String?
    private var remoteLastPortConflictFingerprint: String?

    private static let remoteErrorStatusKey = "remote.error"
    private static let remotePortConflictStatusKey = "remote.port_conflicts"
    private static let remoteHeartbeatDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private var restoredTerminalScrollbackByPanelId: [UUID: String] = [:]

    private static func isProxyOnlyRemoteError(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("remote proxy")
            || lowered.contains("proxy_unavailable")
            || lowered.contains("local daemon proxy")
            || lowered.contains("proxy failure")
            || lowered.contains("daemon transport")
    }

    var focusedSurfaceId: UUID? { focusedPanelId }
    var surfaceDirectories: [UUID: String] {
        get { panelDirectories }
        set { panelDirectories = newValue }
    }

    private var processTitle: String

    private enum SurfaceKind {
        static let terminal = "terminal"
        static let browser = "browser"
        static let markdown = "markdown"
    }

    // MARK: - Initialization

    private static func currentSplitButtonTooltips() -> BonsplitConfiguration.SplitButtonTooltips {
        BonsplitConfiguration.SplitButtonTooltips(
            newTerminal: KeyboardShortcutSettings.Action.newSurface.tooltip(String(localized: "workspace.tooltip.newTerminal", defaultValue: "New Terminal")),
            newBrowser: KeyboardShortcutSettings.Action.openBrowser.tooltip(String(localized: "workspace.tooltip.newBrowser", defaultValue: "New Browser")),
            splitRight: KeyboardShortcutSettings.Action.splitRight.tooltip(String(localized: "workspace.tooltip.splitRight", defaultValue: "Split Right")),
            splitDown: KeyboardShortcutSettings.Action.splitDown.tooltip(String(localized: "workspace.tooltip.splitDown", defaultValue: "Split Down"))
        )
    }

    private static func bonsplitAppearance(from config: GhosttyConfig) -> BonsplitConfiguration.Appearance {
        bonsplitAppearance(
            from: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity
        )
    }

    static func bonsplitChromeHex(backgroundColor: NSColor, backgroundOpacity: Double) -> String {
        let themedColor = GhosttyBackgroundTheme.color(
            backgroundColor: backgroundColor,
            opacity: backgroundOpacity
        )
        let includeAlpha = themedColor.alphaComponent < 0.999
        return themedColor.hexString(includeAlpha: includeAlpha)
    }

    nonisolated static func resolvedChromeColors(
        from backgroundColor: NSColor
    ) -> BonsplitConfiguration.Appearance.ChromeColors {
        .init(backgroundHex: backgroundColor.hexString())
    }

    private static func bonsplitAppearance(
        from backgroundColor: NSColor,
        backgroundOpacity: Double
    ) -> BonsplitConfiguration.Appearance {
        BonsplitConfiguration.Appearance(
            splitButtonTooltips: Self.currentSplitButtonTooltips(),
            enableAnimations: false,
            chromeColors: .init(
                backgroundHex: Self.bonsplitChromeHex(
                    backgroundColor: backgroundColor,
                    backgroundOpacity: backgroundOpacity
                )
            )
        )
    }

    func applyGhosttyChrome(from config: GhosttyConfig, reason: String = "unspecified") {
        applyGhosttyChrome(
            backgroundColor: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity,
            reason: reason
        )
    }

    func applyGhosttyChrome(backgroundColor: NSColor, backgroundOpacity: Double, reason: String = "unspecified") {
        let nextHex = Self.bonsplitChromeHex(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity
        )
        let currentChromeColors = bonsplitController.configuration.appearance.chromeColors
        let isNoOp = currentChromeColors.backgroundHex == nextHex

        if GhosttyApp.shared.backgroundLogEnabled {
            let currentBackgroundHex = currentChromeColors.backgroundHex ?? "nil"
            GhosttyApp.shared.logBackground(
                "theme apply workspace=\(id.uuidString) reason=\(reason) currentBg=\(currentBackgroundHex) nextBg=\(nextHex) noop=\(isNoOp)"
            )
        }

        if isNoOp {
            return
        }
        bonsplitController.configuration.appearance.chromeColors.backgroundHex = nextHex
        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme applied workspace=\(id.uuidString) reason=\(reason) resultingBg=\(bonsplitController.configuration.appearance.chromeColors.backgroundHex ?? "nil") resultingBorder=\(bonsplitController.configuration.appearance.chromeColors.borderHex ?? "nil")"
            )
        }
    }

    func applyGhosttyChrome(backgroundColor: NSColor, reason: String = "unspecified") {
        applyGhosttyChrome(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundColor.alphaComponent,
            reason: reason
        )
    }

    init(
        title: String = "Terminal",
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        configTemplate: ghostty_surface_config_s? = nil,
        initialTerminalCommand: String? = nil,
        initialTerminalEnvironment: [String: String] = [:]
    ) {
        self.id = UUID()
        self.portOrdinal = portOrdinal
        self.processTitle = title
        self.title = title
        self.customTitle = nil
        self.customColor = nil

        let trimmedWorkingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasWorkingDirectory = !trimmedWorkingDirectory.isEmpty
        self.currentDirectory = hasWorkingDirectory
            ? trimmedWorkingDirectory
            : FileManager.default.homeDirectoryForCurrentUser.path

        // Configure bonsplit with keepAllAlive to preserve terminal state
        // and keep split entry instantaneous.
        // Avoid re-reading/parsing Ghostty config on every new workspace; this hot path
        // runs for socket/CLI workspace creation and can cause visible typing lag.
        let appearance = Self.bonsplitAppearance(
            from: GhosttyApp.shared.defaultBackgroundColor,
            backgroundOpacity: GhosttyApp.shared.defaultBackgroundOpacity
        )
        let config = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            allowCloseLastPane: false,
            allowTabReordering: true,
            allowCrossPaneTabMove: true,
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .current,
            appearance: appearance
        )
        self.bonsplitController = BonsplitController(configuration: config)
        bonsplitController.contextMenuShortcuts = Self.buildContextMenuShortcuts()

        // Remove the default "Welcome" tab that bonsplit creates
        let welcomeTabIds = bonsplitController.allTabIds

        // Create initial terminal panel
        let terminalPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            workingDirectory: hasWorkingDirectory ? trimmedWorkingDirectory : nil,
            portOrdinal: portOrdinal,
            initialCommand: initialTerminalCommand,
            initialEnvironmentOverrides: initialTerminalEnvironment
        )
        panels[terminalPanel.id] = terminalPanel
        panelTitles[terminalPanel.id] = terminalPanel.displayTitle

        // Create initial tab in bonsplit and store the mapping
        var initialTabId: TabID?
        if let tabId = bonsplitController.createTab(
            title: title,
            icon: "terminal.fill",
            kind: SurfaceKind.terminal,
            isDirty: false,
            isPinned: false
        ) {
            surfaceIdToPanelId[tabId] = terminalPanel.id
            initialTabId = tabId
        }

        // Close the default Welcome tab(s)
        for welcomeTabId in welcomeTabIds {
            bonsplitController.closeTab(welcomeTabId)
        }

        // Set ourselves as delegate
        bonsplitController.delegate = self

        // Ensure bonsplit has a focused pane and our didSelectTab handler runs for the
        // initial terminal. bonsplit's createTab selects internally but does not emit
        // didSelectTab, and focusedPaneId can otherwise be nil until user interaction.
        if let initialTabId {
            // Focus the pane containing the initial tab (or the first pane as fallback).
            let paneToFocus: PaneID? = {
                for paneId in bonsplitController.allPaneIds {
                    if bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == initialTabId }) {
                        return paneId
                    }
                }
                return bonsplitController.allPaneIds.first
            }()
            if let paneToFocus {
                bonsplitController.focusPane(paneToFocus)
            }
            bonsplitController.selectTab(initialTabId)
        }
    }

    deinit {
        activeRemoteSessionControllerID = nil
        remoteSessionController?.stop()
    }

    func refreshSplitButtonTooltips() {
        var configuration = bonsplitController.configuration
        configuration.appearance.splitButtonTooltips = Self.currentSplitButtonTooltips()
        bonsplitController.configuration = configuration
    }

    // MARK: - Surface ID to Panel ID Mapping

    /// Mapping from bonsplit TabID (surface ID) to panel UUID
    private var surfaceIdToPanelId: [TabID: UUID] = [:]

    /// Tab IDs that are allowed to close even if they would normally require confirmation.
    /// This is used by app-level confirmation prompts (e.g., Cmd+W "Close Tab?") so the
    /// Bonsplit delegate doesn't block the close after the user already confirmed.
    private var forceCloseTabIds: Set<TabID> = []

    /// Tab IDs that are currently showing (or about to show) a close confirmation prompt.
    /// Prevents repeated close gestures (e.g., middle-click spam) from stacking dialogs.
    private var pendingCloseConfirmTabIds: Set<TabID> = []

    /// Deterministic tab selection to apply after a tab closes.
    /// Keyed by the closing tab ID, value is the tab ID we want to select next.
    private var postCloseSelectTabId: [TabID: TabID] = [:]
    private var pendingClosedBrowserRestoreSnapshots: [TabID: ClosedBrowserPanelRestoreSnapshot] = [:]
    private var isApplyingTabSelection = false
    private var pendingTabSelection: (tabId: TabID, pane: PaneID)?
    private var isReconcilingFocusState = false
    private var focusReconcileScheduled = false
#if DEBUG
    private(set) var debugFocusReconcileScheduledDuringDetachCount: Int = 0
#endif
    private var geometryReconcileScheduled = false
    private var isNormalizingPinnedTabOrder = false
    private var pendingNonFocusSplitFocusReassert: PendingNonFocusSplitFocusReassert?
    private var nonFocusSplitFocusReassertGeneration: UInt64 = 0

    private struct PendingNonFocusSplitFocusReassert {
        let generation: UInt64
        let preferredPanelId: UUID
        let splitPanelId: UUID
    }

    struct DetachedSurfaceTransfer {
        let panelId: UUID
        let panel: any Panel
        let title: String
        let icon: String?
        let iconImageData: Data?
        let kind: String?
        let isLoading: Bool
        let isPinned: Bool
        let directory: String?
        let cachedTitle: String?
        let customTitle: String?
        let manuallyUnread: Bool
    }

    private var detachingTabIds: Set<TabID> = []
    private var pendingDetachedSurfaces: [TabID: DetachedSurfaceTransfer] = [:]

    func panelIdFromSurfaceId(_ surfaceId: TabID) -> UUID? {
        surfaceIdToPanelId[surfaceId]
    }

    func surfaceIdFromPanelId(_ panelId: UUID) -> TabID? {
        surfaceIdToPanelId.first { $0.value == panelId }?.key
    }


    private func installBrowserPanelSubscription(_ browserPanel: BrowserPanel) {
        let subscription = Publishers.CombineLatest3(
            browserPanel.$pageTitle.removeDuplicates(),
            browserPanel.$isLoading.removeDuplicates(),
            browserPanel.$faviconPNGData.removeDuplicates(by: { $0 == $1 })
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak browserPanel] _, isLoading, favicon in
            guard let self = self,
                  let browserPanel = browserPanel,
                  let tabId = self.surfaceIdFromPanelId(browserPanel.id) else { return }
            guard let existing = self.bonsplitController.tab(tabId) else { return }

            let nextTitle = browserPanel.displayTitle
            if self.panelTitles[browserPanel.id] != nextTitle {
                self.panelTitles[browserPanel.id] = nextTitle
            }
            let resolvedTitle = self.resolvedPanelTitle(panelId: browserPanel.id, fallback: nextTitle)
            let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
            let faviconUpdate: Data?? = existing.iconImageData == favicon ? nil : .some(favicon)
            let loadingUpdate: Bool? = existing.isLoading == isLoading ? nil : isLoading

            guard titleUpdate != nil || faviconUpdate != nil || loadingUpdate != nil else { return }
            self.bonsplitController.updateTab(
                tabId,
                title: titleUpdate,
                iconImageData: faviconUpdate,
                hasCustomTitle: self.panelCustomTitles[browserPanel.id] != nil,
                isLoading: loadingUpdate
            )
        }
        panelSubscriptions[browserPanel.id] = subscription
    }

    private func browserRemoteWorkspaceStatusSnapshot() -> BrowserRemoteWorkspaceStatus? {
        guard let target = remoteDisplayTarget else { return nil }
        return BrowserRemoteWorkspaceStatus(
            target: target,
            connectionState: remoteConnectionState,
            heartbeatCount: remoteHeartbeatCount,
            lastHeartbeatAt: remoteLastHeartbeatAt
        )
    }

    private func applyBrowserRemoteWorkspaceStatusToPanels() {
        let snapshot = browserRemoteWorkspaceStatusSnapshot()
        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            browserPanel.setRemoteWorkspaceStatus(snapshot)
        }
    }

    private func installMarkdownPanelSubscription(_ markdownPanel: MarkdownPanel) {
        let subscription = markdownPanel.$displayTitle
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak markdownPanel] newTitle in
                guard let self = self,
                      let markdownPanel = markdownPanel,
                      let tabId = self.surfaceIdFromPanelId(markdownPanel.id) else { return }
                guard let existing = self.bonsplitController.tab(tabId) else { return }

                if self.panelTitles[markdownPanel.id] != newTitle {
                    self.panelTitles[markdownPanel.id] = newTitle
                }
                let resolvedTitle = self.resolvedPanelTitle(panelId: markdownPanel.id, fallback: newTitle)
                guard existing.title != resolvedTitle else { return }
                self.bonsplitController.updateTab(
                    tabId,
                    title: resolvedTitle,
                    hasCustomTitle: self.panelCustomTitles[markdownPanel.id] != nil
                )
            }
        panelSubscriptions[markdownPanel.id] = subscription
    }

    // MARK: - Panel Access

    func panel(for surfaceId: TabID) -> (any Panel)? {
        guard let panelId = panelIdFromSurfaceId(surfaceId) else { return nil }
        return panels[panelId]
    }

    func terminalPanel(for panelId: UUID) -> TerminalPanel? {
        panels[panelId] as? TerminalPanel
    }

    func browserPanel(for panelId: UUID) -> BrowserPanel? {
        panels[panelId] as? BrowserPanel
    }

    func markdownPanel(for panelId: UUID) -> MarkdownPanel? {
        panels[panelId] as? MarkdownPanel
    }

    private func surfaceKind(for panel: any Panel) -> String {
        switch panel.panelType {
        case .terminal:
            return SurfaceKind.terminal
        case .browser:
            return SurfaceKind.browser
        case .markdown:
            return SurfaceKind.markdown
        }
    }

    private func resolvedPanelTitle(panelId: UUID, fallback: String) -> String {
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = trimmedFallback.isEmpty ? "Tab" : trimmedFallback
        if let custom = panelCustomTitles[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return fallbackTitle
    }

    private func syncPinnedStateForTab(_ tabId: TabID, panelId: UUID) {
        let isPinned = pinnedPanelIds.contains(panelId)
        if let panel = panels[panelId] {
            bonsplitController.updateTab(
                tabId,
                kind: .some(surfaceKind(for: panel)),
                isPinned: isPinned
            )
        } else {
            bonsplitController.updateTab(tabId, isPinned: isPinned)
        }
    }

    private func hasUnreadNotification(panelId: UUID) -> Bool {
        AppDelegate.shared?.notificationStore?.hasUnreadNotification(forTabId: id, surfaceId: panelId) ?? false
    }

    private func syncUnreadBadgeStateForPanel(_ panelId: UUID) {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        let shouldShowUnread = manualUnreadPanelIds.contains(panelId) || hasUnreadNotification(panelId: panelId)
        if let existing = bonsplitController.tab(tabId), existing.showsNotificationBadge == shouldShowUnread {
            return
        }
        bonsplitController.updateTab(tabId, showsNotificationBadge: shouldShowUnread)
    }

    static func shouldShowUnreadIndicator(hasUnreadNotification: Bool, isManuallyUnread: Bool) -> Bool {
        hasUnreadNotification || isManuallyUnread
    }

    private func normalizePinnedTabs(in paneId: PaneID) {
        guard !isNormalizingPinnedTabOrder else { return }
        isNormalizingPinnedTabOrder = true
        defer { isNormalizingPinnedTabOrder = false }

        let tabs = bonsplitController.tabs(inPane: paneId)
        let pinnedTabs = tabs.filter { tab in
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return false }
            return pinnedPanelIds.contains(panelId)
        }
        let unpinnedTabs = tabs.filter { tab in
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return true }
            return !pinnedPanelIds.contains(panelId)
        }
        let desiredOrder = pinnedTabs + unpinnedTabs

        for (index, desiredTab) in desiredOrder.enumerated() {
            let currentTabs = bonsplitController.tabs(inPane: paneId)
            guard let currentIndex = currentTabs.firstIndex(where: { $0.id == desiredTab.id }) else { continue }
            if currentIndex != index {
                _ = bonsplitController.reorderTab(desiredTab.id, toIndex: index)
            }
        }
    }

    private func insertionIndexToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> Int {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let anchorIndex = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return tabs.count }
        let pinnedCount = tabs.reduce(into: 0) { count, tab in
            if let panelId = panelIdFromSurfaceId(tab.id), pinnedPanelIds.contains(panelId) {
                count += 1
            }
        }
        let rawTarget = min(anchorIndex + 1, tabs.count)
        return max(rawTarget, pinnedCount)
    }

    func setPanelCustomTitle(panelId: UUID, title: String?) {
        guard panels[panelId] != nil else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previous = panelCustomTitles[panelId]
        if trimmed.isEmpty {
            guard previous != nil else { return }
            panelCustomTitles.removeValue(forKey: panelId)
        } else {
            guard previous != trimmed else { return }
            panelCustomTitles[panelId] = trimmed
        }

        guard let panel = panels[panelId], let tabId = surfaceIdFromPanelId(panelId) else { return }
        let baseTitle = panelTitles[panelId] ?? panel.displayTitle
        bonsplitController.updateTab(
            tabId,
            title: resolvedPanelTitle(panelId: panelId, fallback: baseTitle),
            hasCustomTitle: panelCustomTitles[panelId] != nil
        )
    }

    func isPanelPinned(_ panelId: UUID) -> Bool {
        pinnedPanelIds.contains(panelId)
    }

    func panelKind(panelId: UUID) -> String? {
        guard let panel = panels[panelId] else { return nil }
        return surfaceKind(for: panel)
    }

    func requestBackgroundTerminalSurfaceStartIfNeeded() {
        for terminalPanel in panels.values.compactMap({ $0 as? TerminalPanel }) {
            terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
        }
    }

    func hasLoadedTerminalSurface() -> Bool {
        let terminalPanels = panels.values.compactMap { $0 as? TerminalPanel }
        guard !terminalPanels.isEmpty else { return true }
        return terminalPanels.contains { $0.surface.surface != nil }
    }

    func panelTitle(panelId: UUID) -> String? {
        guard let panel = panels[panelId] else { return nil }
        let fallback = panelTitles[panelId] ?? panel.displayTitle
        return resolvedPanelTitle(panelId: panelId, fallback: fallback)
    }

    func setPanelPinned(panelId: UUID, pinned: Bool) {
        guard panels[panelId] != nil else { return }
        let wasPinned = pinnedPanelIds.contains(panelId)
        guard wasPinned != pinned else { return }
        if pinned {
            pinnedPanelIds.insert(panelId)
        } else {
            pinnedPanelIds.remove(panelId)
        }

        guard let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else { return }
        bonsplitController.updateTab(tabId, isPinned: pinned)
        normalizePinnedTabs(in: paneId)
    }

    func markPanelUnread(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        guard manualUnreadPanelIds.insert(panelId).inserted else { return }
        syncUnreadBadgeStateForPanel(panelId)
    }

    func markPanelRead(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        AppDelegate.shared?.notificationStore?.markRead(forTabId: id, surfaceId: panelId)
        clearManualUnread(panelId: panelId)
    }

    func clearManualUnread(panelId: UUID) {
        guard manualUnreadPanelIds.remove(panelId) != nil else { return }
        syncUnreadBadgeStateForPanel(panelId)
    }

    // MARK: - Title Management

    var hasCustomTitle: Bool {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    func applyProcessTitle(_ title: String) {
        processTitle = title
        guard customTitle == nil else { return }
        self.title = title
    }

    func setCustomColor(_ hex: String?) {
        if let hex {
            customColor = WorkspaceTabColorSettings.normalizedHex(hex)
        } else {
            customColor = nil
        }
    }

    func setCustomTitle(_ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            customTitle = nil
            self.title = processTitle
        } else {
            customTitle = trimmed
            self.title = trimmed
        }
    }

    // MARK: - Directory Updates

    func updatePanelDirectory(panelId: UUID, directory: String) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if panelDirectories[panelId] != trimmed {
            panelDirectories[panelId] = trimmed
        }
        // Update current directory if this is the focused panel
        if panelId == focusedPanelId {
            currentDirectory = trimmed
        }
    }

    func updatePanelGitBranch(panelId: UUID, branch: String, isDirty: Bool) {
        let state = SidebarGitBranchState(branch: branch, isDirty: isDirty)
        let existing = panelGitBranches[panelId]
        if existing?.branch != branch || existing?.isDirty != isDirty {
            panelGitBranches[panelId] = state
        }
        if panelId == focusedPanelId {
            gitBranch = state
        }
    }

    func clearPanelGitBranch(panelId: UUID) {
        panelGitBranches.removeValue(forKey: panelId)
        if panelId == focusedPanelId {
            gitBranch = nil
        }
    }

    func updatePanelPullRequest(
        panelId: UUID,
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus
    ) {
        let state = SidebarPullRequestState(number: number, label: label, url: url, status: status)
        let existing = panelPullRequests[panelId]
        if existing != state {
            panelPullRequests[panelId] = state
        }
        if panelId == focusedPanelId {
            pullRequest = state
        }
    }

    func clearPanelPullRequest(panelId: UUID) {
        panelPullRequests.removeValue(forKey: panelId)
        if panelId == focusedPanelId {
            pullRequest = nil
        }
    }

    @discardableResult
    func updatePanelTitle(panelId: UUID, title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var didMutate = false

        if panelTitles[panelId] != trimmed {
            panelTitles[panelId] = trimmed
            didMutate = true
        }

        // Update bonsplit tab title only when this panel's title changed.
        if didMutate,
           let tabId = surfaceIdFromPanelId(panelId),
           let panel = panels[panelId] {
            let baseTitle = panelTitles[panelId] ?? panel.displayTitle
            let resolvedTitle = resolvedPanelTitle(panelId: panelId, fallback: baseTitle)
            bonsplitController.updateTab(
                tabId,
                title: resolvedTitle,
                hasCustomTitle: panelCustomTitles[panelId] != nil
            )
        }

        // If this is the only panel and no custom title, update workspace title
        if panels.count == 1, customTitle == nil {
            if self.title != trimmed {
                self.title = trimmed
                didMutate = true
            }
            if processTitle != trimmed {
                processTitle = trimmed
            }
        }

        return didMutate
    }

    func pruneSurfaceMetadata(validSurfaceIds: Set<UUID>) {
        panelDirectories = panelDirectories.filter { validSurfaceIds.contains($0.key) }
        panelTitles = panelTitles.filter { validSurfaceIds.contains($0.key) }
        panelCustomTitles = panelCustomTitles.filter { validSurfaceIds.contains($0.key) }
        pinnedPanelIds = pinnedPanelIds.filter { validSurfaceIds.contains($0) }
        manualUnreadPanelIds = manualUnreadPanelIds.filter { validSurfaceIds.contains($0) }
        panelGitBranches = panelGitBranches.filter { validSurfaceIds.contains($0.key) }
        surfaceListeningPorts = surfaceListeningPorts.filter { validSurfaceIds.contains($0.key) }
        surfaceTTYNames = surfaceTTYNames.filter { validSurfaceIds.contains($0.key) }
        panelPullRequests = panelPullRequests.filter { validSurfaceIds.contains($0.key) }
        recomputeListeningPorts()
    }

    func recomputeListeningPorts() {
        let unique = Set(surfaceListeningPorts.values.flatMap { $0 }).union(remoteForwardedPorts)
        let next = unique.sorted()
        if listeningPorts != next {
            listeningPorts = next
        }
    }

    func sidebarOrderedPanelIds() -> [UUID] {
        let paneTabs: [String: [UUID]] = Dictionary(
            uniqueKeysWithValues: bonsplitController.allPaneIds.map { paneId in
                let panelIds = bonsplitController
                    .tabs(inPane: paneId)
                    .compactMap { panelIdFromSurfaceId($0.id) }
                return (paneId.id.uuidString, panelIds)
            }
        )

        let fallbackPanelIds = panels.keys.sorted { $0.uuidString < $1.uuidString }
        let tree = bonsplitController.treeSnapshot()
        return SidebarBranchOrdering.orderedPanelIds(
            tree: tree,
            paneTabs: paneTabs,
            fallbackPanelIds: fallbackPanelIds
        )
    }

    func sidebarGitBranchesInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarGitBranchState] {
        SidebarBranchOrdering
            .orderedUniqueBranches(
                orderedPanelIds: orderedPanelIds,
                panelBranches: panelGitBranches,
                fallbackBranch: gitBranch
            )
            .map { SidebarGitBranchState(branch: $0.name, isDirty: $0.isDirty) }
    }

    func sidebarGitBranchesInDisplayOrder() -> [SidebarGitBranchState] {
        sidebarGitBranchesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder(
        orderedPanelIds: [UUID]
    ) -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        SidebarBranchOrdering.orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: orderedPanelIds,
            panelBranches: panelGitBranches,
            panelDirectories: panelDirectories,
            defaultDirectory: currentDirectory,
            fallbackBranch: gitBranch
        )
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder() -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    var isRemoteWorkspace: Bool {
        remoteConfiguration != nil
    }

    func sidebarPullRequestsInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarPullRequestState] {
        SidebarBranchOrdering.orderedUniquePullRequests(
            orderedPanelIds: orderedPanelIds,
            panelPullRequests: panelPullRequests,
            fallbackPullRequest: pullRequest
        )
    }

    func sidebarPullRequestsInDisplayOrder() -> [SidebarPullRequestState] {
        sidebarPullRequestsInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarStatusEntriesInDisplayOrder() -> [SidebarStatusEntry] {
        statusEntries.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.key < rhs.key
        }
    }

    func sidebarMetadataBlocksInDisplayOrder() -> [SidebarMetadataBlock] {
        metadataBlocks.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.key < rhs.key
        }
    }

    // MARK: - Panel Operations

    var remoteDisplayTarget: String? {
        remoteConfiguration?.displayTarget
    }

    func remoteStatusPayload() -> [String: Any] {
        let heartbeatAgeSeconds: Any = {
            guard let last = remoteLastHeartbeatAt else { return NSNull() }
            return max(0, Date().timeIntervalSince(last))
        }()
        let heartbeatTimestamp: Any = {
            guard let last = remoteLastHeartbeatAt else { return NSNull() }
            return Self.remoteHeartbeatDateFormatter.string(from: last)
        }()
        var payload: [String: Any] = [
            "enabled": remoteConfiguration != nil,
            "state": remoteConnectionState.rawValue,
            "connected": remoteConnectionState == .connected,
            "daemon": remoteDaemonStatus.payload(),
            "detected_ports": remoteDetectedPorts,
            "forwarded_ports": remoteForwardedPorts,
            "conflicted_ports": remotePortConflicts,
            "detail": remoteConnectionDetail ?? NSNull(),
            "heartbeat": [
                "count": remoteHeartbeatCount,
                "last_seen_at": heartbeatTimestamp,
                "age_seconds": heartbeatAgeSeconds,
            ],
        ]
        if let endpoint = remoteProxyEndpoint {
            payload["proxy"] = [
                "state": "ready",
                "host": endpoint.host,
                "port": endpoint.port,
                "schemes": ["socks5", "http_connect"],
                "url": "socks5://\(endpoint.host):\(endpoint.port)",
            ]
        } else {
            let proxyState: String
            switch remoteConnectionState {
            case .connecting:
                proxyState = "connecting"
            case .error:
                proxyState = "error"
            default:
                proxyState = "unavailable"
            }
            payload["proxy"] = [
                "state": proxyState,
                "host": NSNull(),
                "port": NSNull(),
                "schemes": ["socks5", "http_connect"],
                "url": NSNull(),
                "error_code": proxyState == "error" ? "proxy_unavailable" : NSNull(),
            ]
        }
        if let remoteConfiguration {
            payload["destination"] = remoteConfiguration.destination
            payload["port"] = remoteConfiguration.port ?? NSNull()
            payload["identity_file"] = remoteConfiguration.identityFile ?? NSNull()
            payload["ssh_options"] = remoteConfiguration.sshOptions
            payload["local_proxy_port"] = remoteConfiguration.localProxyPort ?? NSNull()
        } else {
            payload["destination"] = NSNull()
            payload["port"] = NSNull()
            payload["identity_file"] = NSNull()
            payload["ssh_options"] = []
            payload["local_proxy_port"] = NSNull()
        }
        return payload
    }

    func configureRemoteConnection(_ configuration: WorkspaceRemoteConfiguration, autoConnect: Bool = true) {
        remoteConfiguration = configuration
        remoteDetectedPorts = []
        remoteForwardedPorts = []
        remotePortConflicts = []
        remoteProxyEndpoint = nil
        remoteHeartbeatCount = 0
        remoteLastHeartbeatAt = nil
        remoteConnectionDetail = nil
        remoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
        statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
        remoteLastErrorFingerprint = nil
        remoteLastDaemonErrorFingerprint = nil
        remoteLastPortConflictFingerprint = nil
        recomputeListeningPorts()

        let previousController = remoteSessionController
        activeRemoteSessionControllerID = nil
        remoteSessionController = nil
        previousController?.stop()
        applyRemoteProxyEndpointUpdate(nil)
        applyBrowserRemoteWorkspaceStatusToPanels()

        guard autoConnect else {
            remoteConnectionState = .disconnected
            applyBrowserRemoteWorkspaceStatusToPanels()
            return
        }

        remoteConnectionState = .connecting
        applyBrowserRemoteWorkspaceStatusToPanels()
        let controllerID = UUID()
        let controller = WorkspaceRemoteSessionController(
            workspace: self,
            configuration: configuration,
            controllerID: controllerID
        )
        activeRemoteSessionControllerID = controllerID
        remoteSessionController = controller
        controller.start()
    }

    func reconnectRemoteConnection() {
        guard let configuration = remoteConfiguration else { return }
        configureRemoteConnection(configuration, autoConnect: true)
    }

    func disconnectRemoteConnection(clearConfiguration: Bool = false) {
        let previousController = remoteSessionController
        activeRemoteSessionControllerID = nil
        remoteSessionController = nil
        previousController?.stop()
        remoteDetectedPorts = []
        remoteForwardedPorts = []
        remotePortConflicts = []
        remoteProxyEndpoint = nil
        remoteHeartbeatCount = 0
        remoteLastHeartbeatAt = nil
        remoteConnectionState = .disconnected
        remoteConnectionDetail = nil
        remoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
        statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
        remoteLastErrorFingerprint = nil
        remoteLastDaemonErrorFingerprint = nil
        remoteLastPortConflictFingerprint = nil
        if clearConfiguration {
            remoteConfiguration = nil
        }
        applyRemoteProxyEndpointUpdate(nil)
        applyBrowserRemoteWorkspaceStatusToPanels()
        recomputeListeningPorts()
    }

    func teardownRemoteConnection() {
        disconnectRemoteConnection(clearConfiguration: true)
    }

    fileprivate func applyRemoteConnectionStateUpdate(
        _ state: WorkspaceRemoteConnectionState,
        detail: String?,
        target: String
    ) {
        remoteConnectionState = state
        remoteConnectionDetail = detail
        applyBrowserRemoteWorkspaceStatusToPanels()

        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if state == .error, let trimmedDetail, !trimmedDetail.isEmpty {
            let proxyOnlyError = Self.isProxyOnlyRemoteError(trimmedDetail)
            let statusPrefix = proxyOnlyError ? "Remote proxy unavailable" : "SSH error"
            let statusIcon = proxyOnlyError ? "exclamationmark.triangle.fill" : "network.slash"
            let notificationTitle = proxyOnlyError ? "Remote Proxy Unavailable" : "Remote SSH Error"
            let logSource = proxyOnlyError ? "remote-proxy" : "remote"
            statusEntries[Self.remoteErrorStatusKey] = SidebarStatusEntry(
                key: Self.remoteErrorStatusKey,
                value: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                icon: statusIcon,
                color: nil,
                timestamp: Date()
            )

            let fingerprint = "connection:\(trimmedDetail)"
            if remoteLastErrorFingerprint != fingerprint {
                remoteLastErrorFingerprint = fingerprint
                appendSidebarLog(
                    message: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                    level: .error,
                    source: logSource
                )
                AppDelegate.shared?.notificationStore?.addNotification(
                    tabId: id,
                    surfaceId: nil,
                    title: notificationTitle,
                    subtitle: target,
                    body: trimmedDetail
                )
            }
            return
        }

        if state != .error {
            statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
            remoteLastErrorFingerprint = nil
        }
    }

    fileprivate func applyRemoteDaemonStatusUpdate(_ status: WorkspaceRemoteDaemonStatus, target: String) {
        remoteDaemonStatus = status
        applyBrowserRemoteWorkspaceStatusToPanels()
        guard status.state == .error else {
            remoteLastDaemonErrorFingerprint = nil
            return
        }
        let trimmedDetail = status.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "remote daemon error"
        let fingerprint = "daemon:\(trimmedDetail)"
        guard remoteLastDaemonErrorFingerprint != fingerprint else { return }
        remoteLastDaemonErrorFingerprint = fingerprint
        appendSidebarLog(
            message: "Remote daemon error (\(target)): \(trimmedDetail)",
            level: .error,
            source: "remote-daemon"
        )
    }

    fileprivate func applyRemoteProxyEndpointUpdate(_ endpoint: BrowserProxyEndpoint?) {
        remoteProxyEndpoint = endpoint
        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            browserPanel.setRemoteProxyEndpoint(endpoint)
        }
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    fileprivate func applyRemoteHeartbeatUpdate(count: Int, lastSeenAt: Date?) {
        remoteHeartbeatCount = max(0, count)
        remoteLastHeartbeatAt = lastSeenAt
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    fileprivate func applyRemotePortsSnapshot(detected: [Int], forwarded: [Int], conflicts: [Int], target: String) {
        remoteDetectedPorts = detected
        remoteForwardedPorts = forwarded
        remotePortConflicts = conflicts
        recomputeListeningPorts()

        if conflicts.isEmpty {
            statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
            remoteLastPortConflictFingerprint = nil
            return
        }

        let conflictsList = conflicts.map { ":\($0)" }.joined(separator: ", ")
        statusEntries[Self.remotePortConflictStatusKey] = SidebarStatusEntry(
            key: Self.remotePortConflictStatusKey,
            value: "SSH port conflicts (\(target)): \(conflictsList)",
            icon: "exclamationmark.triangle.fill",
            color: nil,
            timestamp: Date()
        )

        let fingerprint = conflicts.map(String.init).joined(separator: ",")
        guard remoteLastPortConflictFingerprint != fingerprint else { return }
        remoteLastPortConflictFingerprint = fingerprint
        appendSidebarLog(
            message: "Port conflicts while forwarding \(target): \(conflictsList)",
            level: .warning,
            source: "remote-forward"
        )
    }

    private func appendSidebarLog(message: String, level: SidebarLogLevel, source: String?) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logEntries.append(SidebarLogEntry(message: trimmed, level: level, source: source, timestamp: Date()))
        let configuredLimit = UserDefaults.standard.object(forKey: "sidebarMaxLogEntries") as? Int ?? 50
        let limit = max(1, min(500, configuredLimit))
        if logEntries.count > limit {
            logEntries.removeFirst(logEntries.count - limit)
        }
    }

    private func terminalPanelConfigInheritanceCandidates(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> [TerminalPanel] {
        var candidates: [TerminalPanel] = []
        var seen: Set<UUID> = []

        func appendCandidate(_ panel: TerminalPanel?) {
            guard let panel else { return }
            guard seen.insert(panel.id).inserted else { return }
            candidates.append(panel)
        }

        if let preferredPanelId, let preferredTerminal = terminalPanel(for: preferredPanelId) {
            appendCandidate(preferredTerminal)
        }

        appendCandidate(focusedTerminalPanel)

        if let preferredPaneId {
            for tab in bonsplitController.tabs(inPane: preferredPaneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id),
                      let terminalPanel = terminalPanel(for: panelId) else { continue }
                appendCandidate(terminalPanel)
            }
        }

        for terminalPanel in panels.values
            .compactMap({ $0 as? TerminalPanel })
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            appendCandidate(terminalPanel)
        }

        return candidates
    }

    func terminalPanelForConfigInheritance(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> TerminalPanel? {
        terminalPanelConfigInheritanceCandidates(
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        ).first
    }

    // MARK: - Panel Operations

    /// Create a new split with a terminal panel
    @discardableResult
    func newTerminalSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        focus: Bool = true
    ) -> TerminalPanel? {
        // Get inherited config from the source terminal when possible.
        // If the split is initiated from a non-terminal panel (for example browser),
        // fall back to any terminal in the workspace.
        let inheritedConfig: ghostty_surface_config_s? = {
            if let sourceTerminal = terminalPanel(for: panelId),
               let existing = sourceTerminal.surface.surface {
                return ghostty_surface_inherited_config(existing, GHOSTTY_SURFACE_CONTEXT_SPLIT)
            }
            if let fallbackSurface = panels.values
                .compactMap({ ($0 as? TerminalPanel)?.surface.surface })
                .first {
                return ghostty_surface_inherited_config(fallbackSurface, GHOSTTY_SURFACE_CONTEXT_SPLIT)
            }
            return nil
        }()

        // Find the pane containing the source panel
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }

        // Inherit working directory: prefer the source panel's reported cwd,
        // fall back to the workspace's current directory.
        let splitWorkingDirectory: String? = panelDirectories[panelId]
            ?? (currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : currentDirectory)
#if DEBUG
        dlog("split.cwd panelId=\(panelId.uuidString.prefix(5)) panelDir=\(panelDirectories[panelId] ?? "nil") currentDir=\(currentDirectory) resolved=\(splitWorkingDirectory ?? "nil")")
#endif

        // Create the new terminal panel.
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: splitWorkingDirectory,
            portOrdinal: portOrdinal
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle

        // Pre-generate the bonsplit tab ID so we can install the panel mapping before bonsplit
        // mutates layout state (avoids transient "Empty Panel" flashes during split).
        let newTab = Bonsplit.Tab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = newPanel.id
        let previousFocusedPanelId = focusedPanelId

	        // Capture the source terminal's hosted view before bonsplit mutates focusedPaneId,
	        // so we can hand it to focusPanel as the "move focus FROM" view.
	        let previousHostedView = focusedTerminalPanel?.hostedView

	        // Create the split with the new tab already present in the new pane.
	        isProgrammaticSplit = true
	        defer { isProgrammaticSplit = false }
	        guard bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) != nil else {
	            panels.removeValue(forKey: newPanel.id)
	            panelTitles.removeValue(forKey: newPanel.id)
	            surfaceIdToPanelId.removeValue(forKey: newTab.id)
	            return nil
	        }

#if DEBUG
	        dlog("split.created pane=\(paneId.id.uuidString.prefix(5)) orientation=\(orientation)")
#endif

	        // Suppress the old view's becomeFirstResponder side-effects during SwiftUI reparenting.
	        // Without this, reparenting triggers onFocus + ghostty_surface_set_focus on the old view,
	        // stealing focus from the new panel and creating model/surface divergence.
	        if focus {
	            previousHostedView?.suppressReparentFocus()
	            focusPanel(newPanel.id, previousHostedView: previousHostedView)
	            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
	                previousHostedView?.clearSuppressReparentFocus()
	            }
	        } else {
                preserveFocusAfterNonFocusSplit(
                    preferredPanelId: previousFocusedPanelId,
                    splitPanelId: newPanel.id,
                    previousHostedView: previousHostedView
                )
            }

	        return newPanel
	    }

    /// Create a new surface (nested tab) in the specified pane with a terminal panel.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    @discardableResult
    func newTerminalSurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        workingDirectory: String? = nil,
        startupEnvironment: [String: String] = [:]
    ) -> TerminalPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)

        // Get an existing terminal panel to inherit config from
        let inheritedConfig: ghostty_surface_config_s? = {
            for panel in panels.values {
                if let terminalPanel = panel as? TerminalPanel,
                   let surface = terminalPanel.surface.surface {
                    return ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_SPLIT)
                }
            }
            return nil
        }()

        // Create new terminal panel
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            additionalEnvironment: startupEnvironment
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle

        // Create tab in bonsplit
        guard let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = newPanel.id

        // bonsplit's createTab may not reliably emit didSelectTab, and its internal selection
        // updates can be deferred. Force a deterministic selection + focus path so the new
        // surface becomes interactive immediately (no "frozen until pane switch" state).
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            newPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        }
        return newPanel
    }

    /// Create a new browser panel split
    @discardableResult
    func newBrowserSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        url: URL? = nil,
        focus: Bool = true
    ) -> BrowserPanel? {
        // Find the pane containing the source panel
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }

        // Create browser panel
        let browserPanel = BrowserPanel(
            workspaceId: id,
            initialURL: url,
            proxyEndpoint: remoteProxyEndpoint
        )
        panels[browserPanel.id] = browserPanel
        panelTitles[browserPanel.id] = browserPanel.displayTitle

        // Pre-generate the bonsplit tab ID so the mapping exists before the split lands.
        let newTab = Bonsplit.Tab(
            title: browserPanel.displayTitle,
            icon: browserPanel.displayIcon,
            kind: SurfaceKind.browser,
            isDirty: browserPanel.isDirty,
            isLoading: browserPanel.isLoading,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = browserPanel.id
        let previousFocusedPanelId = focusedPanelId

	        // Create the split with the browser tab already present.
	        // Mark this split as programmatic so didSplitPane doesn't auto-create a terminal.
	        isProgrammaticSplit = true
	        defer { isProgrammaticSplit = false }
	        guard bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) != nil else {
	            surfaceIdToPanelId.removeValue(forKey: newTab.id)
	            panels.removeValue(forKey: browserPanel.id)
	            panelTitles.removeValue(forKey: browserPanel.id)
	            return nil
	        }

	        // See newTerminalSplit: suppress old view's becomeFirstResponder during reparenting.
	        let previousHostedView = focusedTerminalPanel?.hostedView
	        if focus {
	            previousHostedView?.suppressReparentFocus()
	            focusPanel(browserPanel.id)
	            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
	                previousHostedView?.clearSuppressReparentFocus()
	            }
	        } else {
                preserveFocusAfterNonFocusSplit(
                    preferredPanelId: previousFocusedPanelId,
                    splitPanelId: browserPanel.id,
                    previousHostedView: previousHostedView
                )
	        }

        installBrowserPanelSubscription(browserPanel)
        browserPanel.setRemoteWorkspaceStatus(browserRemoteWorkspaceStatusSnapshot())

        return browserPanel
    }

    /// Create a new browser surface in the specified pane.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    @discardableResult
    func newBrowserSurface(
        inPane paneId: PaneID,
        url: URL? = nil,
        focus: Bool? = nil,
        insertAtEnd: Bool = false,
        bypassInsecureHTTPHostOnce: String? = nil
    ) -> BrowserPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)

        let browserPanel = BrowserPanel(
            workspaceId: id,
            initialURL: url,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce,
            proxyEndpoint: remoteProxyEndpoint
        )
        panels[browserPanel.id] = browserPanel
        panelTitles[browserPanel.id] = browserPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: browserPanel.displayTitle,
            icon: browserPanel.displayIcon,
            kind: SurfaceKind.browser,
            isDirty: browserPanel.isDirty,
            isLoading: browserPanel.isLoading,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: browserPanel.id)
            panelTitles.removeValue(forKey: browserPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = browserPanel.id

        // Keyboard/browser-open paths want "new tab at end" regardless of global new-tab placement.
        if insertAtEnd {
            let targetIndex = max(0, bonsplitController.tabs(inPane: paneId).count - 1)
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }

        // Match terminal behavior: enforce deterministic selection + focus.
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            browserPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        }

        installBrowserPanelSubscription(browserPanel)
        browserPanel.setRemoteWorkspaceStatus(browserRemoteWorkspaceStatusSnapshot())

        return browserPanel
    }

    // MARK: - Markdown Panel Creation

    /// Create a new markdown panel split from an existing panel.
    func newMarkdownSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        filePath: String,
        focus: Bool = true
    ) -> MarkdownPanel? {
        // Find the pane containing the source panel
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }

        // Create markdown panel
        let markdownPanel = MarkdownPanel(workspaceId: id, filePath: filePath)
        panels[markdownPanel.id] = markdownPanel
        panelTitles[markdownPanel.id] = markdownPanel.displayTitle

        // Pre-generate the bonsplit tab ID so the mapping exists before the split lands.
        let newTab = Bonsplit.Tab(
            title: markdownPanel.displayTitle,
            icon: markdownPanel.displayIcon,
            kind: SurfaceKind.markdown,
            isDirty: markdownPanel.isDirty,
            isLoading: false,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = markdownPanel.id
        let previousFocusedPanelId = focusedPanelId

        // Create the split with the markdown tab already present in the new pane.
        // Mark this split as programmatic so didSplitPane doesn't auto-create a terminal.
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) != nil else {
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            panels.removeValue(forKey: markdownPanel.id)
            panelTitles.removeValue(forKey: markdownPanel.id)
            return nil
        }

        // Suppress old view's becomeFirstResponder during reparenting.
        let previousHostedView = focusedTerminalPanel?.hostedView
        if focus {
            previousHostedView?.suppressReparentFocus()
            focusPanel(markdownPanel.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                previousHostedView?.clearSuppressReparentFocus()
            }
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: markdownPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installMarkdownPanelSubscription(markdownPanel)

        return markdownPanel
    }

    /// Create a new markdown surface (tab) in the specified pane.
    @discardableResult
    func newMarkdownSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool? = nil
    ) -> MarkdownPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)

        let markdownPanel = MarkdownPanel(workspaceId: id, filePath: filePath)
        panels[markdownPanel.id] = markdownPanel
        panelTitles[markdownPanel.id] = markdownPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: markdownPanel.displayTitle,
            icon: markdownPanel.displayIcon,
            kind: SurfaceKind.markdown,
            isDirty: markdownPanel.isDirty,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: markdownPanel.id)
            panelTitles.removeValue(forKey: markdownPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = markdownPanel.id

        // Match terminal behavior: enforce deterministic selection + focus.
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        }

        installMarkdownPanelSubscription(markdownPanel)

        return markdownPanel
    }

    /// Tear down all panels in this workspace, freeing their Ghostty surfaces.
    /// Called before the workspace is removed from TabManager to ensure child
    /// processes receive SIGHUP even if ARC deallocation is delayed.
    func teardownAllPanels() {
        let panelEntries = Array(panels)
        for (panelId, panel) in panelEntries {
            panelSubscriptions.removeValue(forKey: panelId)
            PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
            panel.close()
        }

        panels.removeAll(keepingCapacity: false)
        surfaceIdToPanelId.removeAll(keepingCapacity: false)
        panelSubscriptions.removeAll(keepingCapacity: false)
        pruneSurfaceMetadata(validSurfaceIds: [])
        restoredTerminalScrollbackByPanelId.removeAll(keepingCapacity: false)
        terminalInheritanceFontPointsByPanelId.removeAll(keepingCapacity: false)
        lastTerminalConfigInheritancePanelId = nil
        lastTerminalConfigInheritanceFontPoints = nil
    }

    /// Close a panel.
    /// Returns true when a bonsplit tab close request was issued.
    func closePanel(_ panelId: UUID, force: Bool = false) -> Bool {
#if DEBUG
        let mappedTabIdBeforeClose = surfaceIdFromPanelId(panelId)
        dlog(
            "surface.close.request panel=\(panelId.uuidString.prefix(5)) " +
            "force=\(force ? 1 : 0) mappedTab=\(mappedTabIdBeforeClose.map { String(String(describing: $0).prefix(5)) } ?? "nil") " +
            "focusedPanel=\(focusedPanelId?.uuidString.prefix(5) ?? "nil") " +
            "focusedPane=\(bonsplitController.focusedPaneId?.id.uuidString.prefix(5) ?? "nil") " +
            "\(debugPanelLifecycleState(panelId: panelId, panel: panels[panelId]))"
        )
#endif
        if let tabId = surfaceIdFromPanelId(panelId) {
            if force {
                forceCloseTabIds.insert(tabId)
            }
            // Close the tab in bonsplit (this triggers delegate callback)
            let closed = bonsplitController.closeTab(tabId)
#if DEBUG
            dlog(
                "surface.close.request.done panel=\(panelId.uuidString.prefix(5)) " +
                "tab=\(String(describing: tabId).prefix(5)) closed=\(closed ? 1 : 0) force=\(force ? 1 : 0)"
            )
#endif
            return closed
        }

        // Mapping can transiently drift during split-tree mutations. If the target panel is
        // currently focused (or is the active terminal first responder), close whichever tab
        // bonsplit marks selected in that focused pane.
        let firstResponderPanelId = cmuxOwningGhosttyView(
            for: NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder
        )?.terminalSurface?.id
        let targetIsActive = focusedPanelId == panelId || firstResponderPanelId == panelId
        guard targetIsActive,
              let focusedPane = bonsplitController.focusedPaneId,
              let selected = bonsplitController.selectedTab(inPane: focusedPane) else {
#if DEBUG
            dlog(
                "surface.close.fallback.skip panel=\(panelId.uuidString.prefix(5)) " +
                "focusedPanel=\(focusedPanelId?.uuidString.prefix(5) ?? "nil") " +
                "firstResponderPanel=\(firstResponderPanelId?.uuidString.prefix(5) ?? "nil") " +
                "focusedPane=\(bonsplitController.focusedPaneId?.id.uuidString.prefix(5) ?? "nil")"
            )
#endif
            return false
        }

        if force {
            forceCloseTabIds.insert(selected.id)
        }
        let closed = bonsplitController.closeTab(selected.id)
#if DEBUG
        dlog(
            "surface.close.fallback panel=\(panelId.uuidString.prefix(5)) " +
            "selectedTab=\(String(describing: selected.id).prefix(5)) " +
            "closed=\(closed ? 1 : 0) " +
            "\(debugPanelLifecycleState(panelId: panelId, panel: panels[panelId]))"
        )
#endif
        return closed
    }

#if DEBUG
    private func debugPanelLifecycleState(panelId: UUID, panel: (any Panel)?) -> String {
        guard let panel else { return "panelState=missing" }
        if let terminal = panel as? TerminalPanel {
            let hosted = terminal.hostedView
            let frame = String(format: "%.1fx%.1f", hosted.frame.width, hosted.frame.height)
            let bounds = String(format: "%.1fx%.1f", hosted.bounds.width, hosted.bounds.height)
            let hasRuntimeSurface = terminal.surface.surface != nil ? 1 : 0
            return
                "panelState=terminal panel=\(panelId.uuidString.prefix(5)) " +
                "surface=\(terminal.id.uuidString.prefix(5)) runtimeSurface=\(hasRuntimeSurface) " +
                "inWindow=\(hosted.window != nil ? 1 : 0) hasSuperview=\(hosted.superview != nil ? 1 : 0) " +
                "hidden=\(hosted.isHidden ? 1 : 0) frame=\(frame) bounds=\(bounds)"
        }
        if let browser = panel as? BrowserPanel {
            let webView = browser.webView
            let frame = String(format: "%.1fx%.1f", webView.frame.width, webView.frame.height)
            return
                "panelState=browser panel=\(panelId.uuidString.prefix(5)) " +
                "webInWindow=\(webView.window != nil ? 1 : 0) webHasSuperview=\(webView.superview != nil ? 1 : 0) frame=\(frame)"
        }
        return "panelState=\(String(describing: type(of: panel))) panel=\(panelId.uuidString.prefix(5))"
    }
#endif

    func paneId(forPanelId panelId: UUID) -> PaneID? {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        return bonsplitController.allPaneIds.first { paneId in
            bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
        }
    }

    func indexInPane(forPanelId panelId: UUID) -> Int? {
        guard let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else { return nil }
        return bonsplitController.tabs(inPane: paneId).firstIndex(where: { $0.id == tabId })
    }

    /// Returns the nearest right-side sibling pane for browser placement.
    /// The search is local to the source pane's ancestry in the split tree:
    /// use the closest horizontal ancestor where the source is in the first (left) branch.
    func preferredBrowserTargetPane(fromPanelId panelId: UUID) -> PaneID? {
        guard let sourcePane = paneId(forPanelId: panelId) else { return nil }
        let sourcePaneId = sourcePane.id.uuidString
        let tree = bonsplitController.treeSnapshot()
        guard let path = browserPathToPane(targetPaneId: sourcePaneId, node: tree) else { return nil }

        let layout = bonsplitController.layoutSnapshot()
        let paneFrameById = Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.paneId, $0.frame) })
        let sourceFrame = paneFrameById[sourcePaneId]
        let sourceCenterY = sourceFrame.map { $0.y + ($0.height * 0.5) } ?? 0
        let sourceRightX = sourceFrame.map { $0.x + $0.width } ?? 0

        for crumb in path {
            guard crumb.split.orientation == "horizontal", crumb.branch == .first else { continue }
            var candidateNodes: [ExternalPaneNode] = []
            browserCollectPaneNodes(node: crumb.split.second, into: &candidateNodes)
            if candidateNodes.isEmpty { continue }

            let sorted = candidateNodes.sorted { lhs, rhs in
                let lhsDy = abs((lhs.frame.y + (lhs.frame.height * 0.5)) - sourceCenterY)
                let rhsDy = abs((rhs.frame.y + (rhs.frame.height * 0.5)) - sourceCenterY)
                if lhsDy != rhsDy { return lhsDy < rhsDy }

                let lhsDx = abs(lhs.frame.x - sourceRightX)
                let rhsDx = abs(rhs.frame.x - sourceRightX)
                if lhsDx != rhsDx { return lhsDx < rhsDx }

                if lhs.frame.x != rhs.frame.x { return lhs.frame.x < rhs.frame.x }
                return lhs.id < rhs.id
            }

            for candidate in sorted {
                guard let candidateUUID = UUID(uuidString: candidate.id),
                      candidateUUID != sourcePane.id,
                      let pane = bonsplitController.allPaneIds.first(where: { $0.id == candidateUUID }) else {
                    continue
                }
                return pane
            }
        }

        return nil
    }

    /// Returns the top-right pane in the current split tree.
    /// When a workspace is already split, sidebar PR opens should reuse an existing pane
    /// instead of creating additional right splits.
    func topRightBrowserReusePane() -> PaneID? {
        let paneIds = bonsplitController.allPaneIds
        guard paneIds.count > 1 else { return nil }

        let paneById = Dictionary(uniqueKeysWithValues: paneIds.map { ($0.id.uuidString, $0) })
        var paneBounds: [String: CGRect] = [:]
        browserCollectNormalizedPaneBounds(
            node: bonsplitController.treeSnapshot(),
            availableRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            into: &paneBounds
        )

        guard !paneBounds.isEmpty else {
            return paneIds.sorted { $0.id.uuidString < $1.id.uuidString }.first
        }

        let epsilon = 0.000_1
        let rightMostX = paneBounds.values.map(\.maxX).max() ?? 0

        let sortedCandidates = paneBounds
            .filter { _, rect in abs(rect.maxX - rightMostX) <= epsilon }
            .sorted { lhs, rhs in
                if abs(lhs.value.minY - rhs.value.minY) > epsilon {
                    return lhs.value.minY < rhs.value.minY
                }
                if abs(lhs.value.minX - rhs.value.minX) > epsilon {
                    return lhs.value.minX > rhs.value.minX
                }
                return lhs.key < rhs.key
            }

        for candidate in sortedCandidates {
            if let pane = paneById[candidate.key] {
                return pane
            }
        }

        return paneIds.sorted { $0.id.uuidString < $1.id.uuidString }.first
    }

    private enum BrowserPaneBranch {
        case first
        case second
    }

    private struct BrowserPaneBreadcrumb {
        let split: ExternalSplitNode
        let branch: BrowserPaneBranch
    }

    private func browserPathToPane(targetPaneId: String, node: ExternalTreeNode) -> [BrowserPaneBreadcrumb]? {
        switch node {
        case .pane(let paneNode):
            return paneNode.id == targetPaneId ? [] : nil
        case .split(let splitNode):
            if var path = browserPathToPane(targetPaneId: targetPaneId, node: splitNode.first) {
                path.append(BrowserPaneBreadcrumb(split: splitNode, branch: .first))
                return path
            }
            if var path = browserPathToPane(targetPaneId: targetPaneId, node: splitNode.second) {
                path.append(BrowserPaneBreadcrumb(split: splitNode, branch: .second))
                return path
            }
            return nil
        }
    }

    private func browserCollectPaneNodes(node: ExternalTreeNode, into output: inout [ExternalPaneNode]) {
        switch node {
        case .pane(let paneNode):
            output.append(paneNode)
        case .split(let splitNode):
            browserCollectPaneNodes(node: splitNode.first, into: &output)
            browserCollectPaneNodes(node: splitNode.second, into: &output)
        }
    }

    private func browserCollectNormalizedPaneBounds(
        node: ExternalTreeNode,
        availableRect: CGRect,
        into output: inout [String: CGRect]
    ) {
        switch node {
        case .pane(let paneNode):
            output[paneNode.id] = availableRect
        case .split(let splitNode):
            let divider = min(max(splitNode.dividerPosition, 0), 1)
            let firstRect: CGRect
            let secondRect: CGRect

            if splitNode.orientation.lowercased() == "vertical" {
                // Stacked split: first = top, second = bottom
                firstRect = CGRect(
                    x: availableRect.minX,
                    y: availableRect.minY,
                    width: availableRect.width,
                    height: availableRect.height * divider
                )
                secondRect = CGRect(
                    x: availableRect.minX,
                    y: availableRect.minY + (availableRect.height * divider),
                    width: availableRect.width,
                    height: availableRect.height * (1 - divider)
                )
            } else {
                // Side-by-side split: first = left, second = right
                firstRect = CGRect(
                    x: availableRect.minX,
                    y: availableRect.minY,
                    width: availableRect.width * divider,
                    height: availableRect.height
                )
                secondRect = CGRect(
                    x: availableRect.minX + (availableRect.width * divider),
                    y: availableRect.minY,
                    width: availableRect.width * (1 - divider),
                    height: availableRect.height
                )
            }

            browserCollectNormalizedPaneBounds(node: splitNode.first, availableRect: firstRect, into: &output)
            browserCollectNormalizedPaneBounds(node: splitNode.second, availableRect: secondRect, into: &output)
        }
    }

    private struct BrowserCloseFallbackPlan {
        let orientation: SplitOrientation
        let insertFirst: Bool
        let anchorPaneId: UUID?
    }

    private func stageClosedBrowserRestoreSnapshotIfNeeded(for tab: Bonsplit.Tab, inPane pane: PaneID) {
        guard let panelId = panelIdFromSurfaceId(tab.id),
              let browserPanel = browserPanel(for: panelId),
              let tabIndex = bonsplitController.tabs(inPane: pane).firstIndex(where: { $0.id == tab.id }) else {
            pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tab.id)
            return
        }

        let fallbackPlan = browserCloseFallbackPlan(
            forPaneId: pane.id.uuidString,
            in: bonsplitController.treeSnapshot()
        )
        let resolvedURL = browserPanel.currentURL
            ?? browserPanel.webView.url
            ?? browserPanel.preferredURLStringForOmnibar().flatMap(URL.init(string:))

        pendingClosedBrowserRestoreSnapshots[tab.id] = ClosedBrowserPanelRestoreSnapshot(
            workspaceId: id,
            url: resolvedURL,
            originalPaneId: pane.id,
            originalTabIndex: tabIndex,
            fallbackSplitOrientation: fallbackPlan?.orientation,
            fallbackSplitInsertFirst: fallbackPlan?.insertFirst ?? false,
            fallbackAnchorPaneId: fallbackPlan?.anchorPaneId
        )
    }

    private func clearStagedClosedBrowserRestoreSnapshot(for tabId: TabID) {
        pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tabId)
    }

    private func browserCloseFallbackPlan(
        forPaneId targetPaneId: String,
        in node: ExternalTreeNode
    ) -> BrowserCloseFallbackPlan? {
        switch node {
        case .pane:
            return nil
        case .split(let splitNode):
            if case .pane(let firstPane) = splitNode.first, firstPane.id == targetPaneId {
                return BrowserCloseFallbackPlan(
                    orientation: splitNode.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    insertFirst: true,
                    anchorPaneId: browserNearestPaneId(
                        in: splitNode.second,
                        targetCenter: browserPaneCenter(firstPane)
                    )
                )
            }

            if case .pane(let secondPane) = splitNode.second, secondPane.id == targetPaneId {
                return BrowserCloseFallbackPlan(
                    orientation: splitNode.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    insertFirst: false,
                    anchorPaneId: browserNearestPaneId(
                        in: splitNode.first,
                        targetCenter: browserPaneCenter(secondPane)
                    )
                )
            }

            if let nested = browserCloseFallbackPlan(forPaneId: targetPaneId, in: splitNode.first) {
                return nested
            }
            return browserCloseFallbackPlan(forPaneId: targetPaneId, in: splitNode.second)
        }
    }

    private func browserPaneCenter(_ pane: ExternalPaneNode) -> (x: Double, y: Double) {
        (
            x: pane.frame.x + (pane.frame.width * 0.5),
            y: pane.frame.y + (pane.frame.height * 0.5)
        )
    }

    private func browserNearestPaneId(
        in node: ExternalTreeNode,
        targetCenter: (x: Double, y: Double)?
    ) -> UUID? {
        var panes: [ExternalPaneNode] = []
        browserCollectPaneNodes(node: node, into: &panes)
        guard !panes.isEmpty else { return nil }

        let bestPane: ExternalPaneNode?
        if let targetCenter {
            bestPane = panes.min { lhs, rhs in
                let lhsCenter = browserPaneCenter(lhs)
                let rhsCenter = browserPaneCenter(rhs)
                let lhsDistance = pow(lhsCenter.x - targetCenter.x, 2) + pow(lhsCenter.y - targetCenter.y, 2)
                let rhsDistance = pow(rhsCenter.x - targetCenter.x, 2) + pow(rhsCenter.y - targetCenter.y, 2)
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
                return lhs.id < rhs.id
            }
        } else {
            bestPane = panes.first
        }

        guard let bestPane else { return nil }
        return UUID(uuidString: bestPane.id)
    }

    @discardableResult
    func moveSurface(panelId: UUID, toPane paneId: PaneID, atIndex index: Int? = nil, focus: Bool = true) -> Bool {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return false }
        guard bonsplitController.allPaneIds.contains(paneId) else { return false }
        guard bonsplitController.moveTab(tabId, toPane: paneId, atIndex: index) else { return false }

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            focusPanel(panelId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
    }

    @discardableResult
    func reorderSurface(panelId: UUID, toIndex index: Int) -> Bool {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return false }
        guard bonsplitController.reorderTab(tabId, toIndex: index) else { return false }

        if let paneId = paneId(forPanelId: panelId) {
            applyTabSelection(tabId: tabId, inPane: paneId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
    }

    func detachSurface(panelId: UUID) -> DetachedSurfaceTransfer? {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        guard panels[panelId] != nil else { return nil }

        detachingTabIds.insert(tabId)
        forceCloseTabIds.insert(tabId)
        guard bonsplitController.closeTab(tabId) else {
            detachingTabIds.remove(tabId)
            pendingDetachedSurfaces.removeValue(forKey: tabId)
            forceCloseTabIds.remove(tabId)
            return nil
        }

        return pendingDetachedSurfaces.removeValue(forKey: tabId)
    }

    @discardableResult
    func attachDetachedSurface(
        _ detached: DetachedSurfaceTransfer,
        inPane paneId: PaneID,
        atIndex index: Int? = nil,
        focus: Bool = true
    ) -> UUID? {
        guard bonsplitController.allPaneIds.contains(paneId) else { return nil }
        guard panels[detached.panelId] == nil else { return nil }

        panels[detached.panelId] = detached.panel
        if let terminalPanel = detached.panel as? TerminalPanel {
            terminalPanel.updateWorkspaceId(id)
        } else if let browserPanel = detached.panel as? BrowserPanel {
            browserPanel.updateWorkspaceId(id)
            browserPanel.setRemoteProxyEndpoint(remoteProxyEndpoint)
            browserPanel.setRemoteWorkspaceStatus(browserRemoteWorkspaceStatusSnapshot())
            installBrowserPanelSubscription(browserPanel)
        }

        if let directory = detached.directory {
            panelDirectories[detached.panelId] = directory
        }
        if let cachedTitle = detached.cachedTitle {
            panelTitles[detached.panelId] = cachedTitle
        }
        if let customTitle = detached.customTitle {
            panelCustomTitles[detached.panelId] = customTitle
        }
        if detached.isPinned {
            pinnedPanelIds.insert(detached.panelId)
        } else {
            pinnedPanelIds.remove(detached.panelId)
        }
        if detached.manuallyUnread {
            manualUnreadPanelIds.insert(detached.panelId)
        } else {
            manualUnreadPanelIds.remove(detached.panelId)
        }

        guard let newTabId = bonsplitController.createTab(
            title: detached.title,
            hasCustomTitle: detached.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            icon: detached.icon,
            iconImageData: detached.iconImageData,
            kind: detached.kind,
            isDirty: detached.panel.isDirty,
            isLoading: detached.isLoading,
            isPinned: detached.isPinned,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: detached.panelId)
            panelDirectories.removeValue(forKey: detached.panelId)
            panelTitles.removeValue(forKey: detached.panelId)
            panelCustomTitles.removeValue(forKey: detached.panelId)
            pinnedPanelIds.remove(detached.panelId)
            manualUnreadPanelIds.remove(detached.panelId)
            panelSubscriptions.removeValue(forKey: detached.panelId)
            return nil
        }

        surfaceIdToPanelId[newTabId] = detached.panelId
        if let index {
            _ = bonsplitController.reorderTab(newTabId, toIndex: index)
        }
        syncPinnedStateForTab(newTabId, panelId: detached.panelId)
        syncUnreadBadgeStateForPanel(detached.panelId)
        normalizePinnedTabs(in: paneId)

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            detached.panel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()

        return detached.panelId
    }
    // MARK: - Focus Management

    private func preserveFocusAfterNonFocusSplit(
        preferredPanelId: UUID?,
        splitPanelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?
    ) {
        guard let preferredPanelId, panels[preferredPanelId] != nil else {
            clearNonFocusSplitFocusReassert()
            scheduleFocusReconcile()
            return
        }

        let generation = beginNonFocusSplitFocusReassert(
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )

        reassertFocusAfterNonFocusSplit(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId,
            previousHostedView: previousHostedView,
            allowPreviousHostedView: true
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reassertFocusAfterNonFocusSplit(
                generation: generation,
                preferredPanelId: preferredPanelId,
                splitPanelId: splitPanelId,
                previousHostedView: previousHostedView,
                allowPreviousHostedView: false
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reassertFocusAfterNonFocusSplit(
                    generation: generation,
                    preferredPanelId: preferredPanelId,
                    splitPanelId: splitPanelId,
                    previousHostedView: previousHostedView,
                    allowPreviousHostedView: false
                )
                self.scheduleFocusReconcile()
                self.clearNonFocusSplitFocusReassert(generation: generation)
            }
        }
    }

    private func reassertFocusAfterNonFocusSplit(
        generation: UInt64,
        preferredPanelId: UUID,
        splitPanelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?,
        allowPreviousHostedView: Bool
    ) {
        guard matchesPendingNonFocusSplitFocusReassert(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        ) else {
            return
        }

        guard panels[preferredPanelId] != nil else {
            clearNonFocusSplitFocusReassert(generation: generation)
            return
        }

        if focusedPanelId == splitPanelId {
            focusPanel(
                preferredPanelId,
                previousHostedView: allowPreviousHostedView ? previousHostedView : nil
            )
            return
        }

        guard focusedPanelId == preferredPanelId,
              let terminalPanel = terminalPanel(for: preferredPanelId) else {
            return
        }
        terminalPanel.hostedView.ensureFocus(for: id, surfaceId: preferredPanelId)
    }

    private func beginNonFocusSplitFocusReassert(
        preferredPanelId: UUID,
        splitPanelId: UUID
    ) -> UInt64 {
        nonFocusSplitFocusReassertGeneration &+= 1
        let generation = nonFocusSplitFocusReassertGeneration
        pendingNonFocusSplitFocusReassert = PendingNonFocusSplitFocusReassert(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )
        return generation
    }

    private func matchesPendingNonFocusSplitFocusReassert(
        generation: UInt64,
        preferredPanelId: UUID,
        splitPanelId: UUID
    ) -> Bool {
        guard let pending = pendingNonFocusSplitFocusReassert else { return false }
        return pending.generation == generation &&
            pending.preferredPanelId == preferredPanelId &&
            pending.splitPanelId == splitPanelId
    }

    private func clearNonFocusSplitFocusReassert(generation: UInt64? = nil) {
        guard let pending = pendingNonFocusSplitFocusReassert else { return }
        if let generation, pending.generation != generation { return }
        pendingNonFocusSplitFocusReassert = nil
    }

    private func markExplicitFocusIntent(on panelId: UUID) {
        guard let pending = pendingNonFocusSplitFocusReassert,
              pending.splitPanelId == panelId else {
            return
        }
        pendingNonFocusSplitFocusReassert = nil
    }

    func focusPanel(_ panelId: UUID, previousHostedView: GhosttySurfaceScrollView? = nil) {
        markExplicitFocusIntent(on: panelId)
#if DEBUG
        let pane = bonsplitController.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        dlog("focus.panel panel=\(panelId.uuidString.prefix(5)) pane=\(pane)")
        FocusLogStore.shared.append("Workspace.focusPanel panelId=\(panelId.uuidString) focusedPane=\(pane)")
#endif
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        let currentlyFocusedPanelId = focusedPanelId

        // Capture the currently focused terminal view so we can explicitly move AppKit first
        // responder when focusing another terminal (helps avoid "highlighted but typing goes to
        // another pane" after heavy split/tab mutations).
        // When a caller passes an explicit previousHostedView (e.g. during split creation where
        // bonsplit has already mutated focusedPaneId), prefer it over the derived value.
        let previousTerminalHostedView = previousHostedView ?? focusedTerminalPanel?.hostedView

        // `selectTab` does not necessarily move bonsplit's focused pane. For programmatic focus
        // (socket API, notification click, etc.), ensure the target tab's pane becomes focused
        // so `focusedPanelId` and follow-on focus logic are coherent.
        let targetPaneId = bonsplitController.allPaneIds.first(where: { paneId in
            bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
        })
        let selectionAlreadyConverged: Bool = {
            guard let targetPaneId else { return false }
            return bonsplitController.focusedPaneId == targetPaneId &&
                bonsplitController.selectedTab(inPane: targetPaneId)?.id == tabId
        }()

        if let targetPaneId, !selectionAlreadyConverged {
            bonsplitController.focusPane(targetPaneId)
        }

        if !selectionAlreadyConverged {
            bonsplitController.selectTab(tabId)
        }

        // Also focus the underlying panel
        if let panel = panels[panelId] {
            if currentlyFocusedPanelId != panelId || !selectionAlreadyConverged {
                panel.focus()
            }

            if let terminalPanel = panel as? TerminalPanel {
                // Avoid re-entrant focus loops when focus was initiated by AppKit first-responder
                // (becomeFirstResponder -> onFocus -> focusPanel).
                if !terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                    terminalPanel.hostedView.moveFocus(from: previousTerminalHostedView)
                }
            }
        }
        if let targetPaneId {
            applyTabSelection(tabId: tabId, inPane: targetPaneId)
        }

        if let browserPanel = panels[panelId] as? BrowserPanel {
            // Keep browser find focus behavior aligned with terminal find behavior.
            // When switching back to a pane with an already-open find bar, reassert
            // focus to that field instead of leaving first responder stale.
            if browserPanel.searchState != nil {
                browserPanel.startFind()
            } else {
                maybeAutoFocusBrowserAddressBarOnPanelFocus(browserPanel, trigger: trigger)
            }
        }
    }

    private func maybeAutoFocusBrowserAddressBarOnPanelFocus(
        _ browserPanel: BrowserPanel,
        trigger: FocusPanelTrigger
    ) {
        guard trigger == .standard else { return }
        guard !isCommandPaletteVisibleForWorkspaceWindow() else { return }
        guard !browserPanel.shouldSuppressOmnibarAutofocus() else { return }
        guard browserPanel.isShowingNewTabPage || browserPanel.preferredURLStringForOmnibar() == nil else { return }

        _ = browserPanel.requestAddressBarFocus()
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: browserPanel.id)
    }

    private func isCommandPaletteVisibleForWorkspaceWindow() -> Bool {
        guard let app = AppDelegate.shared else {
            return false
        }

        if let manager = app.tabManagerFor(tabId: id),
           let windowId = app.windowId(for: manager),
           let window = app.mainWindow(for: windowId),
           app.isCommandPaletteVisible(for: window) {
            return true
        }

        if let keyWindow = NSApp.keyWindow, app.isCommandPaletteVisible(for: keyWindow) {
            return true
        }
        if let mainWindow = NSApp.mainWindow, app.isCommandPaletteVisible(for: mainWindow) {
            return true
        }
        return false
    }

    func moveFocus(direction: NavigationDirection) {
        // Unfocus the currently-focused panel before navigating.
        if let prevPanelId = focusedPanelId, let prev = panels[prevPanelId] {
            prev.unfocus()
        }

        bonsplitController.navigateFocus(direction: direction)

        // Always reconcile selection/focus after navigation so AppKit first-responder and
        // bonsplit's focused pane stay aligned, even through split tree mutations.
        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane
    func selectNextSurface() {
        bonsplitController.selectNextTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    /// Select the previous surface in the currently focused pane
    func selectPreviousSurface() {
        bonsplitController.selectPreviousTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    /// Select a surface by index in the currently focused pane
    func selectSurface(at index: Int) {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard index >= 0 && index < tabs.count else { return }
        bonsplitController.selectTab(tabs[index].id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Select the last surface in the currently focused pane
    func selectLastSurface() {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard let last = tabs.last else { return }
        bonsplitController.selectTab(last.id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Create a new terminal surface in the currently focused pane
    @discardableResult
    func newTerminalSurfaceInFocusedPane(focus: Bool? = nil) -> TerminalPanel? {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return nil }
        return newTerminalSurface(inPane: focusedPaneId, focus: focus)
    }

    @discardableResult
    func clearSplitZoom() -> Bool {
        bonsplitController.clearPaneZoom()
    }

    @discardableResult
    func toggleSplitZoom(panelId: UUID) -> Bool {
        guard let paneId = paneId(forPanelId: panelId) else { return false }
        guard bonsplitController.togglePaneZoom(inPane: paneId) else { return false }
        focusPanel(panelId)
        return true
    }

    // MARK: - Context Menu Shortcuts

    static func buildContextMenuShortcuts() -> [TabContextAction: KeyboardShortcut] {
        var shortcuts: [TabContextAction: KeyboardShortcut] = [:]
        let mappings: [(TabContextAction, KeyboardShortcutSettings.Action)] = [
            (.rename, .renameTab),
            (.toggleZoom, .toggleSplitZoom),
            (.newTerminalToRight, .newSurface),
        ]
        for (contextAction, settingsAction) in mappings {
            let stored = KeyboardShortcutSettings.shortcut(for: settingsAction)
            if let key = stored.keyEquivalent {
                shortcuts[contextAction] = KeyboardShortcut(key, modifiers: stored.eventModifiers)
            }
        }
        return shortcuts
    }

    // MARK: - Flash/Notification Support

    func triggerFocusFlash(panelId: UUID) {
        if let terminalPanel = terminalPanel(for: panelId) {
            terminalPanel.triggerFlash()
            return
        }
        if let browserPanel = browserPanel(for: panelId) {
            browserPanel.triggerFlash()
            return
        }
    }

    func triggerNotificationFocusFlash(
        panelId: UUID,
        requiresSplit: Bool = false,
        shouldFocus: Bool = true
    ) {
        guard let terminalPanel = terminalPanel(for: panelId) else { return }
        if shouldFocus {
            focusPanel(panelId)
        }
        let isSplit = bonsplitController.allPaneIds.count > 1 || panels.count > 1
        if requiresSplit && !isSplit {
            return
        }
        terminalPanel.triggerNotificationDismissFlash()
    }

    func triggerDebugFlash(panelId: UUID) {
        triggerNotificationFocusFlash(panelId: panelId, requiresSplit: false, shouldFocus: true)
    }

    // MARK: - Portal Lifecycle

    /// Hide all terminal portal views for this workspace.
    /// Called before the workspace is unmounted to prevent portal-hosted terminal
    /// views from covering browser panes in the newly selected workspace.
    func hideAllTerminalPortalViews() {
        for panel in panels.values {
            guard let terminal = panel as? TerminalPanel else { continue }
            terminal.hostedView.setVisibleInUI(false)
            TerminalWindowPortalRegistry.hideHostedView(terminal.hostedView)
        }
    }

    /// Hide all browser portal views for this workspace.
    /// Called before the workspace is unmounted so a portal-hosted WKWebView
    /// cannot remain visible after this workspace stops being selected.
    func hideAllBrowserPortalViews() {
        for panel in panels.values {
            guard let browser = panel as? BrowserPanel else { continue }
            BrowserWindowPortalRegistry.hide(
                webView: browser.webView,
                source: "workspaceRetire"
            )
        }
    }

    // MARK: - Utility

    /// Create a new terminal panel (used when replacing the last panel)
    @discardableResult
    func createReplacementTerminalPanel() -> TerminalPanel {
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: nil,
            portOrdinal: portOrdinal
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle

        // Create tab in bonsplit
        if let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false
        ) {
            surfaceIdToPanelId[newTabId] = newPanel.id
        }

        return newPanel
    }

    /// Check if any panel needs close confirmation
    func needsConfirmClose() -> Bool {
        for panel in panels.values {
            if let terminalPanel = panel as? TerminalPanel,
               terminalPanel.needsConfirmClose() {
                return true
            }
        }
        return false
    }

    private func reconcileFocusState() {
        guard !isReconcilingFocusState else { return }
        isReconcilingFocusState = true
        defer { isReconcilingFocusState = false }

        // Source of truth: bonsplit focused pane + selected tab.
        // AppKit first responder must converge to this model state, not the other way around.
        var targetPanelId: UUID?

        if let focusedPane = bonsplitController.focusedPaneId,
           let focusedTab = bonsplitController.selectedTab(inPane: focusedPane),
           let mappedPanelId = panelIdFromSurfaceId(focusedTab.id),
           panels[mappedPanelId] != nil {
            targetPanelId = mappedPanelId
        } else {
            for pane in bonsplitController.allPaneIds {
                guard let selectedTab = bonsplitController.selectedTab(inPane: pane),
                      let mappedPanelId = panelIdFromSurfaceId(selectedTab.id),
                      panels[mappedPanelId] != nil else { continue }
                bonsplitController.focusPane(pane)
                bonsplitController.selectTab(selectedTab.id)
                targetPanelId = mappedPanelId
                break
            }
        }

        if targetPanelId == nil, let fallbackPanelId = panels.keys.first {
            targetPanelId = fallbackPanelId
            if let fallbackTabId = surfaceIdFromPanelId(fallbackPanelId),
               let fallbackPane = bonsplitController.allPaneIds.first(where: { paneId in
                   bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == fallbackTabId })
               }) {
                bonsplitController.focusPane(fallbackPane)
                bonsplitController.selectTab(fallbackTabId)
            }
        }

        guard let targetPanelId, let targetPanel = panels[targetPanelId] else { return }

        for (panelId, panel) in panels where panelId != targetPanelId {
            panel.unfocus()
        }

        targetPanel.focus()
        if let terminalPanel = targetPanel as? TerminalPanel {
            terminalPanel.hostedView.ensureFocus(for: id, surfaceId: targetPanelId)
        }
        if let dir = panelDirectories[targetPanelId] {
            currentDirectory = dir
        }
        gitBranch = panelGitBranches[targetPanelId]
        pullRequest = panelPullRequests[targetPanelId]
    }

    /// Reconcile focus/first-responder convergence.
    /// Coalesce to the next main-queue turn so bonsplit selection/pane mutations settle first.
    private func scheduleFocusReconcile() {
#if DEBUG
        if !detachingTabIds.isEmpty {
            debugFocusReconcileScheduledDuringDetachCount += 1
        }
#endif
        guard !focusReconcileScheduled else { return }
        focusReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusReconcileScheduled = false
            self.reconcileFocusState()
        }
    }

    /// Reconcile remaining terminal view geometries after split topology changes.
    /// This keeps AppKit bounds and Ghostty surface sizes in sync in the next runloop turn.
    private func reconcileTerminalGeometryPass() -> Bool {
        var needsFollowUpPass = false

        // Flush pending AppKit layout first so terminal-host bounds reflect latest split topology.
        for window in NSApp.windows {
            window.contentView?.layoutSubtreeIfNeeded()
        }

        for panel in panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            let hostedView = terminalPanel.hostedView
            let hasUsableBounds = hostedView.bounds.width > 1 && hostedView.bounds.height > 1
            let hasSurface = terminalPanel.surface.surface != nil
            let isAttached = hostedView.window != nil && hostedView.superview != nil

            // Split close/reparent churn can transiently detach a surviving terminal view.
            // Force one SwiftUI representable update so the portal binding reattaches it.
            if !isAttached || !hasUsableBounds || !hasSurface {
                terminalPanel.requestViewReattach()
                needsFollowUpPass = true
            }

            let geometryChanged = hostedView.reconcileGeometryNow()
            // Re-check surface after reconcileGeometryNow() which can trigger AppKit
            // layout and view lifecycle changes that free surfaces (#432).
            if geometryChanged, terminalPanel.surface.surface != nil {
                terminalPanel.surface.forceRefresh(reason: "workspace.geometryReconcile")
            }
            if terminalPanel.surface.surface == nil, isAttached && hasUsableBounds {
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
                needsFollowUpPass = true
            }
        }

        return needsFollowUpPass
    }

    private func runScheduledTerminalGeometryReconcile(remainingPasses: Int) {
        guard remainingPasses > 0 else {
            geometryReconcileScheduled = false
            geometryReconcileNeedsRerun = false
            return
        }

        let needsFollowUpPass = reconcileTerminalGeometryPass()
        let shouldRunAgain = geometryReconcileNeedsRerun || needsFollowUpPass

        if shouldRunAgain, remainingPasses > 1 {
            geometryReconcileNeedsRerun = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.runScheduledTerminalGeometryReconcile(remainingPasses: remainingPasses - 1)
            }
            return
        }

        geometryReconcileScheduled = false
        geometryReconcileNeedsRerun = false
    }
    private func scheduleTerminalGeometryReconcile() {
        guard !geometryReconcileScheduled else {
            geometryReconcileNeedsRerun = true
            return
        }
        geometryReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.runScheduledTerminalGeometryReconcile(remainingPasses: 4)
        }
    }

    private func scheduleMovedTerminalRefresh(panelId: UUID) {
        guard terminalPanel(for: panelId) != nil else { return }

        // Force an NSViewRepresentable update after drag/move reparenting. This keeps
        // portal host binding current when a pane auto-closes during tab moves.
        terminalPanel(for: panelId)?.requestViewReattach()

        let runRefreshPass: (TimeInterval) -> Void = { [weak self] delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let self, let panel = self.terminalPanel(for: panelId) else { return }
                let geometryChanged = panel.hostedView.reconcileGeometryNow()
                if geometryChanged, panel.surface.surface != nil {
                    panel.surface.forceRefresh(reason: "workspace.movedTerminalRefresh")
                }
                if panel.surface.surface == nil {
                    panel.surface.requestBackgroundSurfaceStartIfNeeded()
                }
            }
        }

        // Run once immediately and once on the next turn so rapid split close/reparent
        // sequences still get a post-layout redraw.
        runRefreshPass(0)
        runRefreshPass(0.03)
    }

    private func closeTabs(_ tabIds: [TabID], skipPinned: Bool = true) {
        for tabId in tabIds {
            if skipPinned,
               let panelId = panelIdFromSurfaceId(tabId),
               pinnedPanelIds.contains(panelId) {
                continue
            }
            _ = bonsplitController.closeTab(tabId)
        }
    }

    private func tabIdsToLeft(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return [] }
        return Array(tabs.prefix(index).map(\.id))
    }

    private func tabIdsToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }),
              index + 1 < tabs.count else { return [] }
        return Array(tabs.suffix(from: index + 1).map(\.id))
    }

    private func tabIdsToCloseOthers(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        bonsplitController.tabs(inPane: paneId)
            .map(\.id)
            .filter { $0 != anchorTabId }
    }

    private func createTerminalToRight(of anchorTabId: TabID, inPane paneId: PaneID) {
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        guard let newPanel = newTerminalSurface(inPane: paneId, focus: true) else { return }
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
    }

    private func createBrowserToRight(of anchorTabId: TabID, inPane paneId: PaneID, url: URL? = nil) {
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        guard let newPanel = newBrowserSurface(inPane: paneId, url: url, focus: true) else { return }
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
    }

    private func duplicateBrowserToRight(anchorTabId: TabID, inPane paneId: PaneID) {
        guard let panelId = panelIdFromSurfaceId(anchorTabId),
              let browser = browserPanel(for: panelId) else { return }
        createBrowserToRight(of: anchorTabId, inPane: paneId, url: browser.currentURL)
    }

    private func promptRenamePanel(tabId: TabID) {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let panel = panels[panelId] else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "dialog.renameTab.title", defaultValue: "Rename Tab")
        alert.informativeText = String(localized: "dialog.renameTab.message", defaultValue: "Enter a custom name for this tab.")
        let currentTitle = panelCustomTitles[panelId] ?? panelTitles[panelId] ?? panel.displayTitle
        let input = NSTextField(string: currentTitle)
        input.placeholderString = String(localized: "dialog.renameTab.placeholder", defaultValue: "Tab name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "common.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        setPanelCustomTitle(panelId: panelId, title: input.stringValue)
    }

    private enum PanelMoveDestination {
        case newWorkspaceInCurrentWindow
        case selectedWorkspaceInNewWindow
        case existingWorkspace(UUID)
    }

    private func promptMovePanel(tabId: TabID) {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let app = AppDelegate.shared else { return }

        let currentWindowId = app.tabManagerFor(tabId: id).flatMap { app.windowId(for: $0) }
        let workspaceTargets = app.workspaceMoveTargets(
            excludingWorkspaceId: id,
            referenceWindowId: currentWindowId
        )

        var options: [(title: String, destination: PanelMoveDestination)] = [
            (String(localized: "dialog.moveTab.newWorkspaceCurrentWindow", defaultValue: "New Workspace in Current Window"), .newWorkspaceInCurrentWindow),
            (String(localized: "dialog.moveTab.selectedWorkspaceNewWindow", defaultValue: "Selected Workspace in New Window"), .selectedWorkspaceInNewWindow),
        ]
        options.append(contentsOf: workspaceTargets.map { target in
            (target.label, .existingWorkspace(target.workspaceId))
        })

        let alert = NSAlert()
        alert.messageText = String(localized: "dialog.moveTab.title", defaultValue: "Move Tab")
        alert.informativeText = String(localized: "dialog.moveTab.message", defaultValue: "Choose a destination for this tab.")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        for option in options {
            popup.addItem(withTitle: option.title)
        }
        popup.selectItem(at: 0)
        alert.accessoryView = popup
        alert.addButton(withTitle: String(localized: "dialog.moveTab.move", defaultValue: "Move"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selectedIndex = max(0, min(popup.indexOfSelectedItem, options.count - 1))
        let destination = options[selectedIndex].destination

        let moved: Bool
        switch destination {
        case .newWorkspaceInCurrentWindow:
            guard let manager = app.tabManagerFor(tabId: id) else { return }
            let workspace = manager.addWorkspace(select: true)
            moved = app.moveSurface(
                panelId: panelId,
                toWorkspace: workspace.id,
                focus: true,
                focusWindow: false
            )

        case .selectedWorkspaceInNewWindow:
            let newWindowId = app.createMainWindow()
            guard let destinationManager = app.tabManagerFor(windowId: newWindowId),
                  let destinationWorkspaceId = destinationManager.selectedTabId else {
                return
            }
            moved = app.moveSurface(
                panelId: panelId,
                toWorkspace: destinationWorkspaceId,
                focus: true,
                focusWindow: true
            )
            if !moved {
                _ = app.closeMainWindow(windowId: newWindowId)
            }

        case .existingWorkspace(let workspaceId):
            moved = app.moveSurface(
                panelId: panelId,
                toWorkspace: workspaceId,
                focus: true,
                focusWindow: true
            )
        }

        if !moved {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = String(localized: "dialog.moveFailed.title", defaultValue: "Move Failed")
            failure.informativeText = String(localized: "dialog.moveFailed.message", defaultValue: "cmux could not move this tab to the selected destination.")
            failure.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            _ = failure.runModal()
        }
    }

    private func handleExternalTabDrop(_ request: BonsplitController.ExternalTabDropRequest) -> Bool {
        guard let app = AppDelegate.shared else { return false }
#if DEBUG
        let dropStart = ProcessInfo.processInfo.systemUptime
#endif

        let targetPane: PaneID
        let targetIndex: Int?
        let splitTarget: (orientation: SplitOrientation, insertFirst: Bool)?
#if DEBUG
        let destinationLabel: String
#endif

        switch request.destination {
        case .insert(let paneId, let index):
            targetPane = paneId
            targetIndex = index
            splitTarget = nil
#if DEBUG
            destinationLabel = "insert pane=\(paneId.id.uuidString.prefix(5)) index=\(index.map(String.init) ?? "nil")"
#endif
        case .split(let paneId, let orientation, let insertFirst):
            targetPane = paneId
            targetIndex = nil
            splitTarget = (orientation, insertFirst)
#if DEBUG
            destinationLabel = "split pane=\(paneId.id.uuidString.prefix(5)) orientation=\(orientation.rawValue) insertFirst=\(insertFirst ? 1 : 0)"
#endif
        }

        #if DEBUG
        dlog(
            "split.externalDrop.begin ws=\(id.uuidString.prefix(5)) tab=\(request.tabId.uuid.uuidString.prefix(5)) " +
            "sourcePane=\(request.sourcePaneId.id.uuidString.prefix(5)) destination=\(destinationLabel)"
        )
        #endif
        let moved = app.moveBonsplitTab(
            tabId: request.tabId.uuid,
            toWorkspace: id,
            targetPane: targetPane,
            targetIndex: targetIndex,
            splitTarget: splitTarget,
            focus: true,
            focusWindow: true
        )
#if DEBUG
        dlog(
            "split.externalDrop.end ws=\(id.uuidString.prefix(5)) tab=\(request.tabId.uuid.uuidString.prefix(5)) " +
            "moved=\(moved ? 1 : 0) elapsedMs=\(debugElapsedMs(since: dropStart))"
        )
#endif
        return moved
    }
}

// MARK: - BonsplitDelegate

extension Workspace: BonsplitDelegate {
    @MainActor
    private func confirmClosePanel(for tabId: TabID) async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "dialog.closeTab.title", defaultValue: "Close tab?")
        alert.informativeText = String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        // Prefer a sheet if we can find a window, otherwise fall back to modal.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Apply the side-effects of selecting a tab (unfocus others, focus this panel, update state).
    /// bonsplit doesn't always emit didSelectTab for programmatic selection paths (e.g. createTab).
    private func applyTabSelection(tabId: TabID, inPane pane: PaneID) {
        pendingTabSelection = (tabId: tabId, pane: pane)
        guard !isApplyingTabSelection else { return }
        isApplyingTabSelection = true
        defer {
            isApplyingTabSelection = false
            pendingTabSelection = nil
        }

        var iterations = 0
        while let request = pendingTabSelection {
            pendingTabSelection = nil
            iterations += 1
            if iterations > 8 { break }
            applyTabSelectionNow(tabId: request.tabId, inPane: request.pane)
        }
    }

    private func applyTabSelectionNow(tabId: TabID, inPane pane: PaneID) {
        if bonsplitController.allPaneIds.contains(pane) {
            if bonsplitController.focusedPaneId != pane {
                bonsplitController.focusPane(pane)
            }
            if bonsplitController.tabs(inPane: pane).contains(where: { $0.id == tabId }),
               bonsplitController.selectedTab(inPane: pane)?.id != tabId {
                bonsplitController.selectTab(tabId)
            }
        }

        let focusedPane: PaneID
        let selectedTabId: TabID
        if let currentPane = bonsplitController.focusedPaneId,
           let currentTabId = bonsplitController.selectedTab(inPane: currentPane)?.id {
            focusedPane = currentPane
            selectedTabId = currentTabId
        } else if bonsplitController.tabs(inPane: pane).contains(where: { $0.id == tabId }) {
            focusedPane = pane
            selectedTabId = tabId
            bonsplitController.focusPane(focusedPane)
            bonsplitController.selectTab(selectedTabId)
        } else {
            return
        }

        // Focus the selected panel
        guard let panelId = panelIdFromSurfaceId(selectedTabId),
              let panel = panels[panelId] else {
            return
        }
        syncPinnedStateForTab(selectedTabId, panelId: panelId)
        syncUnreadBadgeStateForPanel(panelId)

        // Unfocus all other panels
        for (id, p) in panels where id != panelId {
            p.unfocus()
        }

        panel.focus()
        clearManualUnread(panelId: panelId)

        // Converge AppKit first responder with bonsplit's selected tab in the focused pane.
        // Without this, keyboard input can remain on a different terminal than the blue tab indicator.
        if let terminalPanel = panel as? TerminalPanel {
            terminalPanel.hostedView.ensureFocus(for: id, surfaceId: panelId)
        }

        // Update current directory if this is a terminal
        if let dir = panelDirectories[panelId] {
            currentDirectory = dir
        }
        refreshFocusedGitBranchState()

        // Post notification
        NotificationCenter.default.post(
            name: .ghosttyDidFocusSurface,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: self.id,
                GhosttyNotificationKey.surfaceId: panelId
            ]
        )
    }

    private func refreshFocusedGitBranchState() {
        if let focusedPanelId {
            gitBranch = panelGitBranches[focusedPanelId]
            pullRequest = panelPullRequests[focusedPanelId]
        } else {
            gitBranch = nil
            pullRequest = nil
        }
    }

    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        func recordPostCloseSelection() {
            let tabs = controller.tabs(inPane: pane)
            guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else {
                postCloseSelectTabId.removeValue(forKey: tab.id)
                return
            }

            let target: TabID? = {
                if idx + 1 < tabs.count { return tabs[idx + 1].id }
                if idx > 0 { return tabs[idx - 1].id }
                return nil
            }()

            if let target {
                postCloseSelectTabId[tab.id] = target
            } else {
                postCloseSelectTabId.removeValue(forKey: tab.id)
            }
        }

        if forceCloseTabIds.contains(tab.id) {
            stageClosedBrowserRestoreSnapshotIfNeeded(for: tab, inPane: pane)
            recordPostCloseSelection()
            return true
        }

        if let panelId = panelIdFromSurfaceId(tab.id),
           pinnedPanelIds.contains(panelId) {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            NSSound.beep()
            return false
        }

        // Check if the panel needs close confirmation
        guard let panelId = panelIdFromSurfaceId(tab.id),
              let terminalPanel = terminalPanel(for: panelId) else {
            stageClosedBrowserRestoreSnapshotIfNeeded(for: tab, inPane: pane)
            recordPostCloseSelection()
            return true
        }

        // If confirmation is required, Bonsplit will call into this delegate and we must return false.
        // Show an app-level confirmation, then re-attempt the close with forceCloseTabIds to bypass
        // this gating on the second pass.
        if terminalPanel.needsConfirmClose() {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            if pendingCloseConfirmTabIds.contains(tab.id) {
                return false
            }

            pendingCloseConfirmTabIds.insert(tab.id)
            let tabId = tab.id
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    defer { self.pendingCloseConfirmTabIds.remove(tabId) }

                    // If the tab disappeared while we were scheduling, do nothing.
                    guard self.panelIdFromSurfaceId(tabId) != nil else { return }

                    let confirmed = await self.confirmClosePanel(for: tabId)
                    guard confirmed else { return }

                    self.forceCloseTabIds.insert(tabId)
                    self.bonsplitController.closeTab(tabId)
                }
            }

            return false
        }

        clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
        recordPostCloseSelection()
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID) {
        forceCloseTabIds.remove(tabId)
        let selectTabId = postCloseSelectTabId.removeValue(forKey: tabId)
        let closedBrowserRestoreSnapshot = pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tabId)

        // Clean up our panel
        guard let panelId = panelIdFromSurfaceId(tabId) else {
            #if DEBUG
            dlog(
                "surface.didCloseTab.skip tab=\(String(describing: tabId).prefix(5)) " +
                "pane=\(pane.id.uuidString.prefix(5)) reason=missingPanelMapping " +
                "panels=\(panels.count) panes=\(controller.allPaneIds.count)"
            )
            #endif
            refreshFocusedGitBranchState()
            scheduleTerminalGeometryReconcile()
            scheduleFocusReconcile()
            return
        }

        let panel = panels[panelId]
#if DEBUG
        dlog(
            "surface.didCloseTab.begin tab=\(String(describing: tabId).prefix(5)) " +
            "pane=\(pane.id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "isDetaching=\(isDetaching ? 1 : 0) selectAfter=\(selectTabId.map { String(String(describing: $0).prefix(5)) } ?? "nil") " +
            "\(debugPanelLifecycleState(panelId: panelId, panel: panel))"
        )
#endif

        if isDetaching, let panel {
            let browserPanel = panel as? BrowserPanel
            let cachedTitle = panelTitles[panelId] ?? panel.displayTitle
            pendingDetachedSurfaces[tabId] = DetachedSurfaceTransfer(
                panelId: panelId,
                panel: panel,
                title: resolvedPanelTitle(panelId: panelId, fallback: cachedTitle),
                icon: panel.displayIcon,
                iconImageData: browserPanel?.faviconPNGData,
                kind: surfaceKind(for: panel),
                isLoading: browserPanel?.isLoading ?? false,
                isPinned: pinnedPanelIds.contains(panelId),
                directory: panelDirectories[panelId],
                cachedTitle: panelTitles[panelId],
                customTitle: panelCustomTitles[panelId],
                manuallyUnread: manualUnreadPanelIds.contains(panelId)
            )
        } else {
            if let closedBrowserRestoreSnapshot {
                onClosedBrowserPanel?(closedBrowserRestoreSnapshot)
            }
            panel?.close()
        }

        panels.removeValue(forKey: panelId)
        surfaceIdToPanelId.removeValue(forKey: tabId)
        panelDirectories.removeValue(forKey: panelId)
        panelPullRequests.removeValue(forKey: panelId)
        panelTitles.removeValue(forKey: panelId)
        panelCustomTitles.removeValue(forKey: panelId)
        pinnedPanelIds.remove(panelId)
        manualUnreadPanelIds.remove(panelId)
        panelGitBranches.removeValue(forKey: panelId)
        panelSubscriptions.removeValue(forKey: panelId)
        surfaceTTYNames.removeValue(forKey: panelId)
        restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
        PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)

        // Keep the workspace invariant: always retain at least one real panel.
        // This prevents runtime close callbacks from ever collapsing into a tabless workspace.
        if panels.isEmpty {
            if isDetaching {
                gitBranch = nil
#if DEBUG
                dlog(
                    "surface.didCloseTab.end tab=\(String(describing: tabId).prefix(5)) " +
                    "panel=\(panelId.uuidString.prefix(5)) mode=detachingEmptyWorkspace"
                )
#endif
                scheduleTerminalGeometryReconcile()
                return
            }
            let replacement = createReplacementTerminalPanel()
            if let replacementTabId = surfaceIdFromPanelId(replacement.id),
               let replacementPane = bonsplitController.allPaneIds.first {
                bonsplitController.focusPane(replacementPane)
                bonsplitController.selectTab(replacementTabId)
                applyTabSelection(tabId: replacementTabId, inPane: replacementPane)
            }
            refreshFocusedGitBranchState()
            scheduleTerminalGeometryReconcile()
            scheduleFocusReconcile()
#if DEBUG
            dlog(
                "surface.didCloseTab.end tab=\(String(describing: tabId).prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) mode=replacementCreated " +
                "replacement=\(replacement.id.uuidString.prefix(5)) panels=\(panels.count)"
            )
#endif
            return
        }

        if let selectTabId,
           bonsplitController.allPaneIds.contains(pane),
           bonsplitController.tabs(inPane: pane).contains(where: { $0.id == selectTabId }),
           bonsplitController.focusedPaneId == pane {
            // Keep selection/focus convergence in the same close transaction to avoid a transient
            // frame where the pane has no selected content.
            bonsplitController.selectTab(selectTabId)
            applyTabSelection(tabId: selectTabId, inPane: pane)
        }

        if bonsplitController.allPaneIds.contains(pane) {
            normalizePinnedTabs(in: pane)
        }
        refreshFocusedGitBranchState()
#if DEBUG
        let focusedPaneAfter = bonsplitController.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let focusedPanelAfter = focusedPanelId?.uuidString.prefix(5) ?? "nil"
        dlog(
            "surface.didCloseTab.end tab=\(String(describing: tabId).prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) panels=\(panels.count) panes=\(controller.allPaneIds.count) " +
            "focusedPane=\(focusedPaneAfter) focusedPanel=\(focusedPanelAfter)"
        )
#endif
        refreshFocusedGitBranchState()
        scheduleTerminalGeometryReconcile()
        scheduleFocusReconcile()
    }

    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Bonsplit.Tab, inPane pane: PaneID) {
        applyTabSelection(tabId: tab.id, inPane: pane)
    }

    func splitTabBar(_ controller: BonsplitController, didMoveTab tab: Bonsplit.Tab, fromPane source: PaneID, toPane destination: PaneID) {
#if DEBUG
        let movedPanel = panelIdFromSurfaceId(tab.id)?.uuidString.prefix(5) ?? "unknown"
        dlog(
            "split.moveTab panel=\(movedPanel) " +
            "from=\(source.id.uuidString.prefix(5)) to=\(destination.id.uuidString.prefix(5)) " +
            "sourceTabs=\(controller.tabs(inPane: source).count) destTabs=\(controller.tabs(inPane: destination).count)"
        )
#endif
        applyTabSelection(tabId: tab.id, inPane: destination)
        normalizePinnedTabs(in: source)
        normalizePinnedTabs(in: destination)
        scheduleTerminalGeometryReconcile()
        scheduleFocusReconcile()
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        // When a pane is focused, focus its selected tab's panel
        guard let tab = controller.selectedTab(inPane: pane) else { return }
#if DEBUG
        FocusLogStore.shared.append(
            "Workspace.didFocusPane paneId=\(pane.id.uuidString) tabId=\(tab.id) focusedPane=\(controller.focusedPaneId?.id.uuidString ?? "nil")"
        )
#endif
        applyTabSelection(tabId: tab.id, inPane: pane)

        // Apply window background for terminal
        if let panelId = panelIdFromSurfaceId(tab.id),
           let terminalPanel = panels[panelId] as? TerminalPanel {
            terminalPanel.applyWindowBackgroundIfActive()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID) {
        let closedPanelIds = pendingPaneClosePanelIds.removeValue(forKey: paneId.id) ?? []
        let shouldScheduleFocusReconcile = !isDetachingCloseTransaction
#if DEBUG
        dlog(
            "surface.didClosePane.begin pane=\(paneId.id.uuidString.prefix(5)) " +
            "closedPanels=\(closedPanelIds.count) detaching=\(isDetachingCloseTransaction ? 1 : 0)"
        )
#endif

        if !closedPanelIds.isEmpty {
            for panelId in closedPanelIds {
#if DEBUG
                dlog(
                    "surface.didClosePane.panel pane=\(paneId.id.uuidString.prefix(5)) " +
                    "panel=\(panelId.uuidString.prefix(5)) \(debugPanelLifecycleState(panelId: panelId, panel: panels[panelId]))"
                )
#endif
                panels[panelId]?.close()
                panels.removeValue(forKey: panelId)
                panelDirectories.removeValue(forKey: panelId)
                panelGitBranches.removeValue(forKey: panelId)
                panelPullRequests.removeValue(forKey: panelId)
                panelTitles.removeValue(forKey: panelId)
                panelCustomTitles.removeValue(forKey: panelId)
                pinnedPanelIds.remove(panelId)
                manualUnreadPanelIds.remove(panelId)
                panelSubscriptions.removeValue(forKey: panelId)
                surfaceTTYNames.removeValue(forKey: panelId)
                surfaceListeningPorts.removeValue(forKey: panelId)
                restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
                PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
            }

            let closedSet = Set(closedPanelIds)
            surfaceIdToPanelId = surfaceIdToPanelId.filter { !closedSet.contains($0.value) }
            recomputeListeningPorts()
        }

        refreshFocusedGitBranchState()
        scheduleTerminalGeometryReconcile()
        if shouldScheduleFocusReconcile {
            scheduleFocusReconcile()
        }
#if DEBUG
        dlog(
            "surface.didClosePane.end pane=\(paneId.id.uuidString.prefix(5)) " +
            "remainingPanels=\(panels.count) remainingPanes=\(bonsplitController.allPaneIds.count)"
        )
#endif
    }

    func splitTabBar(_ controller: BonsplitController, shouldClosePane pane: PaneID) -> Bool {
        // Check if any panel in this pane needs close confirmation
        let tabs = controller.tabs(inPane: pane)
        for tab in tabs {
            if forceCloseTabIds.contains(tab.id) { continue }
            if let panelId = panelIdFromSurfaceId(tab.id),
               let terminalPanel = terminalPanel(for: panelId),
               terminalPanel.needsConfirmClose() {
                return false
            }
        }
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation) {
#if DEBUG
        let panelKindForTab: (TabID) -> String = { tabId in
            guard let panelId = self.panelIdFromSurfaceId(tabId),
                  let panel = self.panels[panelId] else { return "placeholder" }
            if panel is TerminalPanel { return "terminal" }
            if panel is BrowserPanel { return "browser" }
            return String(describing: type(of: panel))
        }
        let paneKindSummary: (PaneID) -> String = { paneId in
            let tabs = controller.tabs(inPane: paneId)
            guard !tabs.isEmpty else { return "-" }
            return tabs.map { tab in
                String(panelKindForTab(tab.id).prefix(1))
            }.joined(separator: ",")
        }
        let originalSelectedKind = controller.selectedTab(inPane: originalPane).map { panelKindForTab($0.id) } ?? "none"
        let newSelectedKind = controller.selectedTab(inPane: newPane).map { panelKindForTab($0.id) } ?? "none"
        dlog(
            "split.didSplit original=\(originalPane.id.uuidString.prefix(5)) new=\(newPane.id.uuidString.prefix(5)) " +
            "orientation=\(orientation) programmatic=\(isProgrammaticSplit ? 1 : 0) " +
            "originalTabs=\(controller.tabs(inPane: originalPane).count) newTabs=\(controller.tabs(inPane: newPane).count) " +
            "originalSelected=\(originalSelectedKind) newSelected=\(newSelectedKind) " +
            "originalKinds=[\(paneKindSummary(originalPane))] newKinds=[\(paneKindSummary(newPane))]"
        )
#endif
        // Only auto-create a terminal if the split came from bonsplit UI.
        // Programmatic splits via newTerminalSplit() set isProgrammaticSplit and handle their own panels.
        guard !isProgrammaticSplit else {
            normalizePinnedTabs(in: originalPane)
            normalizePinnedTabs(in: newPane)
            scheduleTerminalGeometryReconcile()
            return
        }

        // If the new pane already has a tab, this split moved an existing tab (drag-to-split).
        //
        // In the "drag the only tab to split edge" case, bonsplit inserts a placeholder "Empty"
        // tab in the source pane to avoid leaving it tabless. In cmux, this is undesirable:
        // it creates a pane with no real surfaces and leaves an "Empty" tab in the tab bar.
        //
        // Replace placeholder-only source panes with a real terminal surface, then drop the
        // placeholder tabs so the UI stays consistent and pane lists don't contain empties.
        if !controller.tabs(inPane: newPane).isEmpty {
            let originalTabs = controller.tabs(inPane: originalPane)
            let hasRealSurface = originalTabs.contains { panelIdFromSurfaceId($0.id) != nil }
#if DEBUG
            dlog(
                "split.didSplit.drag original=\(originalPane.id.uuidString.prefix(5)) " +
                "new=\(newPane.id.uuidString.prefix(5)) originalTabs=\(originalTabs.count) " +
                "newTabs=\(controller.tabs(inPane: newPane).count) hasRealSurface=\(hasRealSurface ? 1 : 0) " +
                "originalKinds=[\(paneKindSummary(originalPane))] newKinds=[\(paneKindSummary(newPane))]"
            )
#endif
            if !hasRealSurface {
                let placeholderTabs = originalTabs.filter { panelIdFromSurfaceId($0.id) == nil }
#if DEBUG
                dlog(
                    "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
                    "action=reusePlaceholder placeholderCount=\(placeholderTabs.count)"
                )
#endif
                if let replacementTab = placeholderTabs.first {
                    // Keep the existing placeholder tab identity and replace only the panel mapping.
                    // This avoids an extra create+close tab churn that can transiently render an
                    // empty pane during drag-to-split of a single-tab pane.
                    let inheritedConfig: ghostty_surface_config_s? = {
                        for panel in panels.values {
                            if let terminalPanel = panel as? TerminalPanel,
                               let surface = terminalPanel.surface.surface {
                                return ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_SPLIT)
                            }
                        }
                        return nil
                    }()

                    let replacementPanel = TerminalPanel(
                        workspaceId: id,
                        context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                        configTemplate: inheritedConfig,
                        portOrdinal: portOrdinal
                    )
                    panels[replacementPanel.id] = replacementPanel
                    panelTitles[replacementPanel.id] = replacementPanel.displayTitle
                    surfaceIdToPanelId[replacementTab.id] = replacementPanel.id

                    bonsplitController.updateTab(
                        replacementTab.id,
                        title: replacementPanel.displayTitle,
                        icon: .some(replacementPanel.displayIcon),
                        iconImageData: .some(nil),
                        kind: .some(SurfaceKind.terminal),
                        hasCustomTitle: false,
                        isDirty: replacementPanel.isDirty,
                        showsNotificationBadge: false,
                        isLoading: false,
                        isPinned: false
                    )

                    for extraPlaceholder in placeholderTabs.dropFirst() {
                        bonsplitController.closeTab(extraPlaceholder.id)
                    }
                } else {
#if DEBUG
                    dlog(
                        "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
                        "fallback=createTerminalAndDropPlaceholders"
                    )
#endif
                    _ = newTerminalSurface(inPane: originalPane, focus: false)
                    for tab in controller.tabs(inPane: originalPane) {
                        if panelIdFromSurfaceId(tab.id) == nil {
                            bonsplitController.closeTab(tab.id)
                        }
                    }
                }
            }
            normalizePinnedTabs(in: originalPane)
            normalizePinnedTabs(in: newPane)
            scheduleTerminalGeometryReconcile()
            return
        }

        // Mirror Cmd+D behavior: split buttons should always seed a terminal in the new pane.
        // When the focused source is a browser, inherit terminal config from nearby terminals
        // (or fall back to defaults) instead of leaving an empty selector pane.
        let sourceTabId = controller.selectedTab(inPane: originalPane)?.id
        let sourcePanelId = sourceTabId.flatMap { panelIdFromSurfaceId($0) }

#if DEBUG
        dlog(
            "split.didSplit.autoCreate pane=\(newPane.id.uuidString.prefix(5)) " +
            "fromPane=\(originalPane.id.uuidString.prefix(5)) sourcePanel=\(sourcePanelId.map { String($0.uuidString.prefix(5)) } ?? "none")"
        )
#endif

        let inheritedConfig: ghostty_surface_config_s? = if let existing = sourcePanel.surface.surface {
            ghostty_surface_inherited_config(existing, GHOSTTY_SURFACE_CONTEXT_SPLIT)
        } else {
            nil
        }

        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            portOrdinal: portOrdinal
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false,
            inPane: newPane
        ) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            return
        }

        surfaceIdToPanelId[newTabId] = newPanel.id
        normalizePinnedTabs(in: newPane)
#if DEBUG
        dlog(
            "split.didSplit.autoCreate.done pane=\(newPane.id.uuidString.prefix(5)) " +
            "panel=\(newPanel.id.uuidString.prefix(5))"
        )
#endif

        // `createTab` selects the new tab but does not emit didSelectTab; schedule an explicit
        // selection so our focus/unfocus logic runs after this delegate callback returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.bonsplitController.focusedPaneId == newPane {
                self.bonsplitController.selectTab(newTabId)
            }
            self.scheduleTerminalGeometryReconcile()
            self.scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didRequestNewTab kind: String, inPane pane: PaneID) {
        switch kind {
        case "terminal":
            _ = newTerminalSurface(inPane: pane)
        case "browser":
            _ = newBrowserSurface(inPane: pane)
        default:
            _ = newTerminalSurface(inPane: pane)
        }
    }

    func splitTabBar(_ controller: BonsplitController, didRequestTabContextAction action: TabContextAction, for tab: Bonsplit.Tab, inPane pane: PaneID) {
        switch action {
        case .rename:
            promptRenamePanel(tabId: tab.id)
        case .clearName:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            setPanelCustomTitle(panelId: panelId, title: nil)
        case .closeToLeft:
            closeTabs(tabIdsToLeft(of: tab.id, inPane: pane))
        case .closeToRight:
            closeTabs(tabIdsToRight(of: tab.id, inPane: pane))
        case .closeOthers:
            closeTabs(tabIdsToCloseOthers(of: tab.id, inPane: pane))
        case .move:
            // TODO: Wire this to a move target picker.
            return
        case .newTerminalToRight:
            createTerminalToRight(of: tab.id, inPane: pane)
        case .newBrowserToRight:
            createBrowserToRight(of: tab.id, inPane: pane)
        case .reload:
            guard let panelId = panelIdFromSurfaceId(tab.id),
                  let browser = browserPanel(for: panelId) else { return }
            browser.reload()
        case .duplicate:
            duplicateBrowserToRight(anchorTabId: tab.id, inPane: pane)
        case .togglePin:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            let shouldPin = !pinnedPanelIds.contains(panelId)
            setPanelPinned(panelId: panelId, pinned: shouldPin)
        case .markAsRead:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            clearManualUnread(panelId: panelId)
            AppDelegate.shared?.notificationStore?.markRead(forTabId: id, surfaceId: panelId)
        case .markAsUnread:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            markPanelUnread(panelId)
        case .toggleZoom:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            toggleSplitZoom(panelId: panelId)
        @unknown default:
            break
        }
    }

    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot) {
        _ = snapshot
        scheduleTerminalGeometryReconcile()
        scheduleFocusReconcile()
    }

    // No post-close polling refresh loop: we rely on view invariants and Ghostty's wakeups.
}
