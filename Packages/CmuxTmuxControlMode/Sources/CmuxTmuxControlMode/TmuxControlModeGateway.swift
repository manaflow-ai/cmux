import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A local `tmux -CC` control-mode session: spawns the gateway process on a
/// pseudo-terminal, pumps its output through ``TmuxControlModeSessionCore``, and
/// writes commands to it. Conforms to ``ControlModeSessionSource`` so the app
/// wires it to a manual-IO Ghostty surface without knowing it is tmux.
///
/// `tmux -CC` requires a real terminal (it calls `tcgetattr` on its standard
/// streams and exits if they are plain pipes), so the gateway runs on a PTY
/// whose master end we read/write. All ``TmuxControlModeSessionCore`` access is
/// serialized on a private queue; delegate callbacks are invoked on the main
/// queue (the app stays on the main actor).
public final class TmuxControlModeGateway: ControlModeSessionSource, @unchecked Sendable {
    private let target: TmuxAttachTarget
    private let tmuxExecutablePath: String
    private let workingDirectory: String?
    private let environment: [String: String]?

    private let queue = DispatchQueue(label: "com.cmux.tmux-control-mode.gateway")
    private var core = TmuxControlModeSessionCore()
    private var delegate: (any ControlModeSessionDelegate)?

    private let process = Process()
    private var masterHandle: FileHandle?
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

            // tmux -CC needs a controlling terminal; allocate a PTY and run it
            // on the slave end, reading/writing the master.
            var master: Int32 = 0
            var slave: Int32 = 0
            var ws = winsize(
                ws_row: UInt16(clamping: initialSize.rows),
                ws_col: UInt16(clamping: initialSize.columns),
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            guard openpty(&master, &slave, nil, nil, &ws) == 0 else {
                deliverEnd(reason: "failed to allocate pty for tmux")
                return
            }

            // Raw slave so the commands we write are not echoed back into the
            // control stream.
            var term = termios()
            if tcgetattr(slave, &term) == 0 {
                cfmakeraw(&term)
                _ = tcsetattr(slave, TCSANOW, &term)
            }

            process.executableURL = URL(fileURLWithPath: tmuxExecutablePath)
            process.arguments = ["-CC"] + target.tmuxArguments
            process.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
            process.standardOutput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
            process.standardError = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
            if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
            if let environment { process.environment = environment }

            let mHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
            masterHandle = mHandle
            mHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self else { return }
                if data.isEmpty {
                    handle.readabilityHandler = nil // EOF; termination handler delivers the end.
                    return
                }
                self.queue.async { self.apply(self.core.consume([UInt8](data))) }
            }

            process.terminationHandler = { [weak self] proc in
                guard let self else { return }
                let reason = proc.terminationStatus == 0 ? nil : "tmux exited (\(proc.terminationStatus))"
                self.queue.async { self.apply(self.core.gatewayExited(reason: reason)) }
            }

            do {
                try process.run()
            } catch {
                close(slave)
                deliverEnd(reason: "failed to launch tmux: \(error.localizedDescription)")
                return
            }
            // The child holds the slave now; close our copy so the master sees
            // EOF when tmux exits.
            close(slave)

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
                deliverEnd(reason: reason)
            }
        }
    }

    private func deliverEnd(reason: String?) {
        guard !finished else { return }
        finished = true
        let delegate = self.delegate
        DispatchQueue.main.async { delegate?.controlModeSession(didEndWithReason: reason) }
    }

    private func writeToGateway(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, let masterHandle else { return }
        do {
            try masterHandle.write(contentsOf: Data(bytes))
        } catch {
            // Broken pipe -> the gateway is gone; the termination handler
            // delivers the end-of-session.
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
