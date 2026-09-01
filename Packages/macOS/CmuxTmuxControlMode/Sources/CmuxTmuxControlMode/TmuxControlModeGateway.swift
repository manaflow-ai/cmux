import Foundation

/// A local `tmux -CC` control-mode session: spawns the gateway process, pumps
/// its stdout through ``TmuxControlModeSessionCore``, and writes commands to its
/// stdin. Conforms to ``ControlModeSessionSource`` so the app wires it to a
/// manual-IO Ghostty surface without knowing it is tmux.
///
/// All ``TmuxControlModeSessionCore`` access is serialized on a private queue;
/// delegate callbacks are invoked on that queue (the app hops to the main actor).
public final class TmuxControlModeGateway: ControlModeSessionSource, @unchecked Sendable {
    private let target: TmuxAttachTarget
    private let tmuxExecutablePath: String
    private let workingDirectory: String?
    private let environment: [String: String]?

    private let queue = DispatchQueue(label: "com.cmux.tmux-control-mode.gateway")
    private var core = TmuxControlModeSessionCore()
    private weak var delegate: (any ControlModeSessionDelegate)?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var launched = false
    private var finished = false

    public var displayName: String {
        switch target {
        case .mostRecent: return "tmux"
        case let .session(name): return "tmux: \(name)"
        }
    }

    public init(
        target: TmuxAttachTarget,
        tmuxExecutablePath: String,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil
    ) {
        self.target = target
        self.tmuxExecutablePath = tmuxExecutablePath
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    public func start(initialSize: TerminalSize, delegate: any ControlModeSessionDelegate) {
        queue.async { [self] in
            guard !launched else { return }
            launched = true
            self.delegate = delegate

            process.executableURL = URL(fileURLWithPath: tmuxExecutablePath)
            process.arguments = ["-CC"] + target.tmuxArguments
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stdoutPipe // fold stderr into the stream; control protocol ignores stray lines
            if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
            if let environment { process.environment = environment }

            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self else { return }
                if data.isEmpty {
                    // EOF; termination handler will deliver the end-of-session.
                    handle.readabilityHandler = nil
                    return
                }
                self.queue.async {
                    self.apply(self.core.consume([UInt8](data)))
                }
            }

            process.terminationHandler = { [weak self] proc in
                guard let self else { return }
                let reason = proc.terminationStatus == 0 ? nil : "tmux exited (\(proc.terminationStatus))"
                self.queue.async {
                    self.apply(self.core.gatewayExited(reason: reason))
                }
            }

            do {
                try process.run()
            } catch {
                finished = true
                let delegate = self.delegate
                DispatchQueue.main.async {
                    delegate?.controlModeSession(didEndWithReason: "failed to launch tmux: \(error.localizedDescription)")
                }
                return
            }

            apply(core.start(initialSize: initialSize))
        }
    }

    public func sendInput(_ bytes: [UInt8]) {
        queue.async { [self] in
            guard launched, !finished else { return }
            apply(core.sendInput(bytes))
        }
    }

    public func resize(_ size: TerminalSize) {
        queue.async { [self] in
            guard launched, !finished else { return }
            apply(core.resize(size))
        }
    }

    public func stop() {
        queue.async { [self] in
            guard launched, !finished else { return }
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: - Effect application (always on `queue`)

    private func apply(_ effects: [TmuxControlModeSessionCore.Effect]) {
        guard !effects.isEmpty else { return }
        for effect in effects {
            switch effect {
            case let .write(bytes):
                writeToGateway(bytes)
            case let .snapshot(bytes):
                let delegate = self.delegate
                DispatchQueue.main.async { delegate?.controlModeSession(didProduceSnapshot: bytes) }
            case let .output(bytes):
                let delegate = self.delegate
                DispatchQueue.main.async { delegate?.controlModeSession(didProduceOutput: bytes) }
            case let .ended(reason):
                guard !finished else { continue }
                finished = true
                let delegate = self.delegate
                DispatchQueue.main.async { delegate?.controlModeSession(didEndWithReason: reason) }
            }
        }
    }

    private func writeToGateway(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data(bytes))
        } catch {
            // Broken pipe -> the gateway is gone; let the termination handler
            // deliver the end-of-session.
        }
    }

    // MARK: - tmux discovery

    /// Resolve an absolute `tmux` path from common locations and `PATH`.
    /// Returns nil when tmux is not installed. Pass `pathEnvironment` to search
    /// a specific `PATH`; nil falls back to the current process environment.
    public static func resolveTmuxExecutable(pathEnvironment: String? = nil) -> String? {
        let fm = FileManager.default
        var candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        let searchPath = pathEnvironment ?? ProcessInfo.processInfo.environment["PATH"]
        if let searchPath {
            for dir in searchPath.split(separator: ":") {
                candidates.append("\(dir)/tmux")
            }
        }
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }
}
