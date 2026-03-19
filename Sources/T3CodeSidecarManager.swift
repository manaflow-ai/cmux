import Darwin
import Foundation
import os

/// Manages a t3code Node.js server process for a single workspace.
/// Spawns the server with a preselected port, confirms startup via the
/// sidecar state directory, and handles restart/shutdown with deduplication.
final class T3CodeSidecarManager {

    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "T3CodeSidecar")

    /// The configured server port for this sidecar process.
    private(set) var port: Int?

    /// The workspace's project directory (used as cwd and state-dir base).
    let projectDirectory: URL

    /// The .cmux state directory for this workspace.
    private var stateDir: String { projectDirectory.appendingPathComponent(".cmux").path }

    /// The port file path inside the state directory.
    private var portFilePath: String { (stateDir as NSString).appendingPathComponent("server.port") }

    /// The running Node.js process.
    private var process: Process?

    /// Whether we're intentionally shutting down (suppress restart).
    private var isShuttingDown = false

    /// Whether a restart is already scheduled (prevent duplicate restarts).
    private var isRestartPending = false

    /// Timer for polling the port file.
    private var portPollTimer: DispatchSourceTimer?

    /// Prevent duplicate port publication while startup probes converge.
    private var hasPublishedPort = false

    /// Callback when a port is assigned so consumers can start readiness polling.
    var onReady: ((Int) -> Void)?

    /// Callback when server crashes unexpectedly.
    var onCrash: (() -> Void)?

    init(projectDirectory: URL) {
        self.projectDirectory = projectDirectory
    }

    deinit {
        shutdown()
    }

    // MARK: - Lifecycle

    /// Start the t3code server process.
    func start() {
        guard process == nil else {
            logger.warning("Sidecar already running for \(self.projectDirectory.path)")
            return
        }

        isShuttingDown = false
        isRestartPending = false
        hasPublishedPort = false

        // Create .cmux directory if needed
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)

        // Clean up stale port file from previous run
        try? FileManager.default.removeItem(atPath: portFilePath)

        // Locate the t3code server binary
        guard let serverBinary = resolveServerBinary() else {
            logger.error("Could not find t3code server binary")
            return
        }

        logger.info("Using t3code binary: \(serverBinary)")

        guard let selectedPort = port ?? reserveAvailablePort() else {
            logger.error("Could not reserve a local port for the t3code sidecar")
            return
        }
        port = selectedPort

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [
            "node",
            serverBinary,
            "--port", String(selectedPort),
            "--state-dir", stateDir,
            "--auto-bootstrap-project-from-cwd",
            "--no-browser",
            "--mode", "web"
        ]
        proc.currentDirectoryURL = projectDirectory

        // Inherit environment but ensure PATH includes common Node locations
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin", "/Users/\(NSUserName())/.bun/bin"]
        if let existingPath = env["PATH"] {
            env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
        }
        // The embedded cmux sidecar is loopback-only and does not plumb auth tokens
        // into the webview/WebSocket client. Ignore any shell-level token override
        // inherited from the user's environment so the local chat can hydrate.
        env.removeValue(forKey: "T3CODE_AUTH_TOKEN")
        proc.environment = env

        // Let stdout/stderr go to /dev/null — cmux relies on the known port
        // and probes the embedded URL directly.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        // Handle unexpected termination
        proc.terminationHandler = { [weak self] proc in
            guard let self = self, !self.isShuttingDown else { return }
            self.logger.error("t3code sidecar exited unexpectedly (code \(proc.terminationStatus))")
            self.process = nil
            self.port = nil
            self.stopPortPolling()
            DispatchQueue.main.async {
                self.onCrash?()
            }
        }

        do {
            try proc.run()
            self.process = proc
            logger.info(
                "Spawned t3code sidecar (PID \(proc.processIdentifier)) on port \(selectedPort) for \(self.projectDirectory.path)"
            )
            publishPort(selectedPort)
        } catch {
            logger.error("Failed to spawn t3code sidecar: \(error.localizedDescription)")
            port = nil
            return
        }

        // Keep polling the port file for confirmation and timeout diagnostics.
        startPortPolling()
    }

    /// Gracefully shut down the sidecar process.
    func shutdown() {
        isShuttingDown = true
        stopPortPolling()

        guard let proc = process, proc.isRunning else {
            process = nil
            return
        }

        logger.info("Shutting down t3code sidecar (PID \(proc.processIdentifier))")
        proc.terminate()  // SIGTERM

        // Force kill after 5 seconds if still running
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, let proc = self.process, proc.isRunning else { return }
            self.logger.warning("Force killing t3code sidecar (PID \(proc.processIdentifier))")
            kill(proc.processIdentifier, SIGKILL)
        }

        process = nil
        port = nil
        hasPublishedPort = false

        // Clean up port file
        try? FileManager.default.removeItem(atPath: portFilePath)
    }

    /// Restart the sidecar (used after crash detection). Deduplicates.
    func restart() {
        guard !isRestartPending else {
            logger.info("Restart already pending, skipping duplicate")
            return
        }
        isRestartPending = true
        shutdown()
        // Delay to let port be released and SQLite locks clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.start()
        }
    }

    // MARK: - Port File Polling

    /// Poll the state directory for a server.port file written by t3code.
    private func startPortPolling() {
        stopPortPolling()

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1.0)

        var attempts = 0
        let maxAttempts = 30  // Give up after 30 seconds

        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            attempts += 1

            // Check for port file written by t3code server on startup
            if let portStr = try? String(contentsOfFile: self.portFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let port = Int(portStr), port > 0 {
                self.logger.info("Detected t3code port \(port) from port file at \(self.portFilePath)")
                self.handlePortDetected(port)
                return
            }

            // Check if process is still alive
            if let proc = self.process, !proc.isRunning {
                self.logger.error("t3code process died while waiting for port file")
                self.stopPortPolling()
                return
            }

            if attempts >= maxAttempts {
                self.logger.error("Timed out waiting for t3code port file after \(maxAttempts)s at \(self.portFilePath)")
                self.stopPortPolling()
            }
        }

        timer.resume()
        self.portPollTimer = timer
    }

    private func stopPortPolling() {
        portPollTimer?.cancel()
        portPollTimer = nil
    }

    private func handlePortDetected(_ port: Int) {
        self.stopPortPolling()
        publishPort(port)
    }

    private func publishPort(_ port: Int) {
        self.port = port
        guard !hasPublishedPort else { return }
        hasPublishedPort = true
        DispatchQueue.main.async { [weak self] in
            self?.onReady?(port)
        }
    }

    private func reserveAvailablePort() -> Int? {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: in_addr_t(0))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }

        guard bindResult == 0 else { return nil }

        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(socketFD, sockaddrPointer, &length)
            }
        }

        guard nameResult == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    // Port detection is done via port file polling only (see startPortPolling).
    // The t3code server writes {stateDir}/server.port on startup.

    // MARK: - Server Binary Resolution

    /// Find the t3code server binary.
    private func resolveServerBinary() -> String? {
        // 1. Check T3CODE_SERVER_PATH environment variable
        if let t3codePath = ProcessInfo.processInfo.environment["T3CODE_SERVER_PATH"],
           FileManager.default.fileExists(atPath: t3codePath) {
            return t3codePath
        }

        // 2. Check via Xcode source root (Info.plist CMUXSourceRoot key)
        #if DEBUG
        if let sourceRoot = Bundle.main.infoDictionary?["CMUXSourceRoot"] as? String {
            let monorepoRoot = (sourceRoot as NSString).deletingLastPathComponent
            let candidate = (monorepoRoot as NSString).appendingPathComponent("t3code/apps/server/dist/index.mjs")
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        #endif

        // 3. Walk up from project directory looking for t3code sibling
        var searchDir = projectDirectory.path
        for _ in 0..<6 {
            let candidate = (searchDir as NSString).appendingPathComponent("t3code/apps/server/dist/index.mjs")
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            let parent = (searchDir as NSString).deletingLastPathComponent
            if parent == searchDir { break }
            searchDir = parent
        }

        // 4. Check well-known development paths
        #if DEBUG
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let devPaths = [
            (homeDir as NSString).appendingPathComponent("Projekte/cmux-t3code/t3code/apps/server/dist/index.mjs"),
            (homeDir as NSString).appendingPathComponent("Projects/cmux-t3code/t3code/apps/server/dist/index.mjs"),
        ]
        for path in devPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        #endif

        // 5. Check common global install paths
        let globalPaths = [
            "/usr/local/lib/node_modules/t3/dist/index.mjs",
            "/opt/homebrew/lib/node_modules/t3/dist/index.mjs",
        ]
        for path in globalPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // 6. Check app bundle resources
        if let bundledPath = Bundle.main.path(forResource: "t3code-server", ofType: "mjs") {
            return bundledPath
        }

        logger.warning("t3code server binary not found. Set T3CODE_SERVER_PATH env var.")
        return nil
    }
}
