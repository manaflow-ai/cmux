public import Foundation
public import CmuxTerminalCore
import Dispatch
import os

/// A renderer for the documented Zellij pane subscription API.
///
/// Zellij does not expose tmux-like raw control mode. `subscribe --format
/// json --ansi` sends complete rendered viewport lines, while input and
/// scrolling are separate one-shot `zellij action` commands. This source keeps
/// those two protocols separate and never presents rendered text as a raw VT
/// byte stream.
public final class ZellijRenderedSessionGateway: TerminalSessionSource, @unchecked Sendable {
    public static let defaultScrollbackLines = 2_000
    public static let maximumFrameBytes = 16 * 1024 * 1024

    private let sessionName: String
    private let paneID: String
    private let remoteDestination: String?
    private let zellijExecutablePath: String
    private let environment: [String: String]?
    private let scrollbackLines: Int

    private let queue = DispatchQueue(label: "com.cmux.zellij-rendered-session.gateway")
    private var parser = ZellijRenderedSessionParser(
        maximumRecordBytes: ZellijRenderedSessionGateway.maximumFrameBytes,
        maximumFrameBytes: ZellijRenderedSessionGateway.maximumFrameBytes
    )
    private weak var delegate: (any TerminalSessionSourceDelegate)?
    private var eventDelivery: TerminalSessionSourceEventDelivery?
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdoutReader: ControlModeProcessOutputReader?
    private var stderrReader: ControlModeProcessOutputReader?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var actionExecutor: ZellijActionExecutor?
    private var launched = false
    private var stopping = false
    private var finished = false
    private var stdoutEnded = false
    private var stderrEnded = false
    private var terminationStatus: Int32?
    private var transportFailureReason: String?
    private var stderrTail = ""
    private var sawFrame = false
    private var closedReason: String?
    private var currentSize = TerminalSize(columns: 80, rows: 24)

    private static let maxStderrBytes = 8 * 1024

    public var displayName: String { "zellij: \(sessionName):\(paneID)" }

    /// Zellij's subscription owns a rendered viewport, so scroll is a
    /// semantic action rather than local Ghostty scrolling.
    public var supportsSemanticScroll: Bool { true }

    /// The documented CLI has no command that sets a subscription client's
    /// exact viewport size. Relative `action resize` changes the foreign
    /// layout, so this source refuses that operation explicitly.
    public var supportsExactResize: Bool { false }

    /// Resolve Zellij from the same non-interactive locations used by Harbor
    /// discovery. GUI-launched processes often do not inherit the user's
    /// shell PATH, so the common Homebrew and local-bin paths are explicit.
    public static func resolveZellijExecutable(pathEnvironment: String? = nil) -> String? {
        let fileManager = FileManager.default
        var candidates = [
            "\(NSHomeDirectory())/.local/bin/zellij",
            "/opt/homebrew/bin/zellij",
            "/usr/local/bin/zellij",
            "/opt/local/bin/zellij",
            "/usr/bin/zellij",
            "/bin/zellij",
        ]
        if let pathEnvironment {
            candidates.append(contentsOf: pathEnvironment.split(separator: ":").map { "\($0)/zellij" })
        } else if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/zellij" })
        }
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) })
    }

    public init(
        sessionName: String,
        paneID: String,
        zellijExecutablePath: String,
        remoteDestination: String? = nil,
        environment: [String: String]? = nil,
        scrollbackLines: Int = ZellijRenderedSessionGateway.defaultScrollbackLines
    ) {
        self.sessionName = sessionName
        self.paneID = paneID
        self.zellijExecutablePath = zellijExecutablePath
        self.remoteDestination = remoteDestination
        self.environment = environment
        self.scrollbackLines = max(0, scrollbackLines)
    }

    public func start(initialSize: TerminalSize, delegate: any TerminalSessionSourceDelegate) {
        queue.async { [self] in
            guard !launched, !stopping else { return }
            launched = true
            currentSize = initialSize
            self.delegate = delegate
            self.eventDelivery = TerminalSessionSourceEventDelivery(delegate: delegate)
            configureProcess()

            guard let stdoutReader = ControlModeProcessOutputReader(
                readingFrom: stdoutPipe.fileHandleForReading,
                label: "com.cmux.zellij-rendered-session.stdout.\(UUID().uuidString)",
                maxPendingChunks: 4096,
                maxPendingBytes: 32 * 1024 * 1024,
                onOverflow: { [weak self] in
                    self?.queue.async { [weak self] in
                        self?.handleTransportFailure("zellij subscription output exceeded its bounded buffer")
                    }
                }
            ) else {
                finish(termination: .failed(reason: "failed to attach Zellij subscription output reader"))
                return
            }
            guard let stderrReader = ControlModeProcessOutputReader(
                readingFrom: stderrPipe.fileHandleForReading,
                label: "com.cmux.zellij-rendered-session.stderr.\(UUID().uuidString)",
                maxPendingChunks: 256,
                maxPendingBytes: 1024 * 1024,
                onOverflow: { [weak self] in
                    self?.queue.async { [weak self] in
                        self?.handleTransportFailure("zellij subscription diagnostics exceeded its bounded buffer")
                    }
                }
            ) else {
                stdoutReader.close()
                finish(termination: .failed(reason: "failed to attach Zellij subscription diagnostics reader"))
                return
            }
            self.stdoutReader = stdoutReader
            self.stderrReader = stderrReader
            self.actionExecutor = ZellijActionExecutor(
                sessionName: sessionName,
                paneID: paneID,
                remoteDestination: remoteDestination,
                zellijExecutablePath: zellijExecutablePath,
                environment: environment,
                onFailure: { [weak self] reason in
                    self?.queue.async { [weak self] in
                        self?.handleTransportFailure(reason)
                    }
                }
            )

            stdoutTask = Task { [weak self, stdoutReader] in
                for await chunk in stdoutReader.stream {
                    guard let self else {
                        stdoutReader.release(chunk)
                        return
                    }
                    await self.enqueueOnProtocolQueue { [weak self, stdoutReader, chunk] in
                        defer { stdoutReader.release(chunk) }
                        guard let self, !self.finished else { return }
                        self.apply(self.parser.consume(Array(chunk)))
                    }
                }
                if let self {
                    await self.enqueueOnProtocolQueue { [weak self] in
                        guard let self else { return }
                        self.apply(self.parser.finish())
                        self.stdoutDidEnd()
                    }
                }
            }
            stderrTask = Task { [weak self, stderrReader] in
                for await chunk in stderrReader.stream {
                    guard let self else {
                        stderrReader.release(chunk)
                        return
                    }
                    await self.enqueueOnProtocolQueue { [weak self, stderrReader, chunk] in
                        defer { stderrReader.release(chunk) }
                        guard let self else { return }
                        self.appendStderr(chunk)
                    }
                }
                if let self {
                    await self.enqueueOnProtocolQueue { [weak self] in
                        guard let self else { return }
                        self.stderrEnded = true
                        self.finishAfterTransportDrainIfReady()
                    }
                }
            }

            process.terminationHandler = { [weak self, stdoutReader, stderrReader] process in
                // Process termination and pipe EOF are separate events. Let
                // both readers publish bytes already in the kernel before the
                // gateway classifies the subscription.
                stdoutReader.processDidExit()
                stderrReader.processDidExit()
                guard let self else { return }
                let status = process.terminationStatus
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.terminationStatus = status
                    self.finishAfterTransportDrainIfReady()
                }
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                stdoutReader.close()
                stderrReader.close()
                finish(termination: .failed(reason: "failed to launch Zellij subscription: \(error.localizedDescription)"))
                return
            }

            // The reader objects own duplicated descriptors. Closing the
            // parent's copies after launch makes EOF observable and prevents a
            // hidden reference from keeping a dead subscription alive.
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
        }
    }

    public func sendInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.finished, !self.stopping else { return }
            guard self.actionExecutor?.enqueueWrite(bytes) == true else {
                self.handleTransportFailure("zellij input action queue is unavailable")
                return
            }
        }
    }

    public func sendScroll(_ command: TerminalScrollCommand) {
        queue.async { [weak self] in
            guard let self, !self.finished, !self.stopping else { return }
            guard self.actionExecutor?.enqueueScroll(command) == true else {
                self.handleTransportFailure("zellij scroll action queue is unavailable")
                return
            }
        }
    }

    public func resize(_ size: TerminalSize) {
        // Keep the latest size for diagnostics and future frame policy. Do not
        // call `zellij action resize`: that command changes the user's layout,
        // not this read-only subscription's viewport.
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.currentSize = size
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.stopping = true
            self.actionExecutor?.stop()
            if !self.launched {
                self.finish(termination: .ended(reason: nil))
            } else if self.process.isRunning {
                self.process.terminate()
            } else {
                self.finishAfterTransportDrainIfReady()
            }
        }
    }

    // MARK: Subscription process

    private func configureProcess() {
        if let remoteDestination {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = Self.remoteSubscribeArguments(
                destination: remoteDestination,
                sessionName: sessionName,
                paneID: paneID,
                scrollbackLines: scrollbackLines
            )
        } else {
            process.executableURL = URL(fileURLWithPath: zellijExecutablePath)
            process.arguments = Self.subscribeArguments(
                sessionName: sessionName,
                paneID: paneID,
                scrollbackLines: scrollbackLines
            )
        }
        // `subscribe` never reads stdin. A null device avoids creating an
        // accidental input channel that could block process teardown.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) {
                _, override in override
            }
        }
    }

    public static func subscribeArguments(
        sessionName: String,
        paneID: String,
        scrollbackLines: Int = ZellijRenderedSessionGateway.defaultScrollbackLines
    ) -> [String] {
        var arguments = [
            "--session", sessionName,
            "subscribe",
            "--pane-id", paneID,
            "--format", "json",
            "--ansi",
        ]
        if scrollbackLines > 0 {
            arguments += ["--scrollback", String(scrollbackLines)]
        }
        return arguments
    }

    public static func remoteSubscribeArguments(
        destination: String,
        sessionName: String,
        paneID: String,
        scrollbackLines: Int = ZellijRenderedSessionGateway.defaultScrollbackLines
    ) -> [String] {
        let command = subscribeArguments(
            sessionName: sessionName,
            paneID: paneID,
            scrollbackLines: scrollbackLines
        ).map(shellQuote).joined(separator: " ")
        return [
            "-T",
            "-o", "EscapeChar=none",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "--", destination, "zellij \(command)",
        ]
    }

    /// Renders one complete Zellij update into a replacement frame for the
    /// local Ghostty emulator. Scrollback is written first, then each viewport
    /// row is positioned explicitly so a long preceding row cannot shift the
    /// following rows.
    public static func renderFrame(
        scrollback: [String]?,
        viewport: [String]
    ) -> [UInt8] {
        var bytes = TerminalSessionSnapshot.replacing([])
        bytes.append(contentsOf: Array("\u{1B}[2J\u{1B}[H".utf8))
        if let scrollback {
            for line in scrollback {
                bytes.append(contentsOf: Array(line.utf8))
                bytes.append(contentsOf: [0x0D, 0x0A])
            }
        }
        for (index, line) in viewport.enumerated() {
            bytes.append(contentsOf: Array("\u{1B}[\(index + 1);1H".utf8))
            bytes.append(contentsOf: Array(line.utf8))
            bytes.append(contentsOf: [0x1B, 0x5B, 0x4B]) // CSI K
        }
        return bytes
    }

    private func apply(_ events: [ZellijRenderedSessionEvent]) {
        guard !finished else { return }
        for event in events {
            switch event {
            case let .update(paneID, viewport, scrollback, _):
                guard paneID == self.paneID else {
                    finish(termination: .failed(reason: "zellij subscription returned an unexpected pane"))
                    break
                }
                if !sawFrame {
                    sawFrame = true
                    enqueueDelegateEvent(.resizePolicy(.preserveScreen))
                }
                let frame = Self.renderFrame(scrollback: scrollback, viewport: viewport)
                guard frame.count <= Self.maximumFrameBytes + TerminalSessionSnapshot.replacementPrefix.count else {
                    finish(termination: .failed(reason: "zellij rendered frame exceeded its bounded size"))
                    break
                }
                // Every update is a complete viewport. Sending it as a
                // replacement prevents stale rows when the foreign pane
                // shrinks or changes its local layout.
                enqueueDelegateEvent(.snapshot(frame))
            case let .closed(paneID):
                guard paneID == self.paneID else {
                    finish(termination: .failed(reason: "zellij closed an unexpected pane"))
                    break
                }
                closedReason = "zellij pane closed"
                finish(termination: .ended(reason: closedReason))
            case let .protocolError(reason):
                finish(termination: .failed(reason: reason))
            }
            if finished { break }
        }
    }

    private func enqueueDelegateEvent(_ event: TerminalSessionSourceEventDelivery.Event) {
        guard !finished, let eventDelivery else { return }
        guard eventDelivery.enqueue(event) else {
            handleTransportFailure("zellij delegate delivery exceeded its bounded buffer")
            return
        }
    }

    private func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrTail += String(decoding: data, as: UTF8.self)
        if stderrTail.utf8.count > Self.maxStderrBytes {
            stderrTail = String(decoding: Array(stderrTail.utf8.suffix(Self.maxStderrBytes)), as: UTF8.self)
        }
    }

    private func stdoutDidEnd() {
        guard !stdoutEnded else { return }
        stdoutEnded = true
        guard !finished else { return }
        if terminationStatus == nil {
            if !stopping { handleTransportFailure("zellij subscription stream closed") }
        } else {
            finishAfterTransportDrainIfReady()
        }
    }

    private func handleTransportFailure(_ reason: String) {
        guard !finished else { return }
        transportFailureReason = transportFailureReason ?? reason
        if process.isRunning { process.terminate() }
        finishAfterTransportDrainIfReady()
    }

    private func finishAfterTransportDrainIfReady() {
        guard !finished, terminationStatus != nil, stdoutEnded, stderrEnded else { return }
        let termination: TerminalSessionTermination
        if let transportFailureReason {
            termination = .failed(reason: transportFailureReason)
        } else if stopping {
            termination = .ended(reason: nil)
        } else if let closedReason {
            termination = .ended(reason: closedReason)
        } else if terminationStatus != 0 {
            let diagnostic = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            termination = .failed(
                reason: diagnostic.isEmpty ? "zellij exited (\(terminationStatus!))" : diagnostic
            )
        } else {
            termination = .failed(reason: "zellij subscription ended without a pane_closed record")
        }
        finish(termination: termination)
    }

    private func finish(termination: TerminalSessionTermination) {
        guard !finished else { return }
        finished = true
        let delivery = eventDelivery
        let delegate = self.delegate
        actionExecutor?.stop()
        closeTransport()
        if let delivery {
            delivery.finish(termination)
        } else {
            Task { @MainActor in
                delegate?.controlModeSession(didTerminate: termination)
            }
        }
    }

    private func closeTransport() {
        process.terminationHandler = nil
        stdoutTask?.cancel()
        stdoutTask = nil
        stderrTask?.cancel()
        stderrTask = nil
        stdoutReader?.close()
        stdoutReader = nil
        stderrReader?.close()
        stderrReader = nil
        actionExecutor?.stop()
        actionExecutor = nil
        try? stdoutPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func enqueueOnProtocolQueue(_ operation: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                defer { continuation.resume() }
                operation()
            }
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Serializes Zellij's one-shot action commands. The public Zellij protocol
/// has no persistent action channel, so this executor is the narrow boundary
/// where subprocess cost is paid. Input is chunked and bounded, and commands
/// are never launched concurrently because Zellij documents no ordering
/// guarantee for concurrent CLI actions on one pane.
private final class ZellijActionExecutor: @unchecked Sendable {
    private enum Action: Sendable {
        case write([UInt8])
        case scroll(name: String, count: Int)
    }

    private struct State {
        var pending: [Action] = []
        var pendingUnits = 0
        var running = false
        var stopped = false
        var failureReported = false
        var currentProcess: Process?
    }

    private let sessionName: String
    private let paneID: String
    private let remoteDestination: String?
    private let zellijExecutablePath: String
    private let environment: [String: String]?
    private let onFailure: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "com.cmux.zellij-rendered-session.actions")
    private let lock = NSLock()
    private var state = State()

    private static let maximumPendingUnits = 2 * 1024 * 1024
    private static let maximumWriteBytesPerInvocation = 4 * 1024
    private static let maximumScrollActionsPerRecord = 256

    init(
        sessionName: String,
        paneID: String,
        remoteDestination: String?,
        zellijExecutablePath: String,
        environment: [String: String]?,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.sessionName = sessionName
        self.paneID = paneID
        self.remoteDestination = remoteDestination
        self.zellijExecutablePath = zellijExecutablePath
        self.environment = environment
        self.onFailure = onFailure
    }

    deinit { stop() }

    func enqueueWrite(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        var accepted = true
        var start = 0
        while start < bytes.count {
            let end = min(start + Self.maximumWriteBytesPerInvocation, bytes.count)
            if !enqueue(.write(Array(bytes[start..<end])), units: end - start) {
                accepted = false
                break
            }
            start = end
        }
        return accepted
    }

    func enqueueScroll(_ command: TerminalScrollCommand) -> Bool {
        let base = command.source == .pageKey
            ? (command.direction == .up ? "page-scroll-up" : "page-scroll-down")
            : (command.direction == .up ? "scroll-up" : "scroll-down")
        var remaining = command.source == .pageKey ? 1 : Int(command.lines)
        var accepted = true
        while remaining > 0 {
            let count = min(remaining, Self.maximumScrollActionsPerRecord)
            if !enqueue(.scroll(name: base, count: count), units: count) {
                accepted = false
                break
            }
            remaining -= count
        }
        return accepted
    }

    func stop() {
        lock.lock()
        state.stopped = true
        state.pending.removeAll(keepingCapacity: false)
        state.pendingUnits = 0
        let process = state.currentProcess
        lock.unlock()
        process?.terminate()
    }

    private func enqueue(_ action: Action, units: Int) -> Bool {
        let shouldStart: Bool
        lock.lock()
        guard !state.stopped,
              units > 0,
              units <= Self.maximumPendingUnits - state.pendingUnits else {
            lock.unlock()
            reportFailure("zellij action queue exceeded its bounded buffer")
            return false
        }
        state.pending.append(action)
        state.pendingUnits += units
        shouldStart = !state.running
        if shouldStart { state.running = true }
        lock.unlock()
        if shouldStart { queue.async { [weak self] in self?.runQueue() } }
        return true
    }

    private func runQueue() {
        while let action = popNext() {
            guard execute(action) else {
                reportFailure("zellij action command failed")
                stop()
                return
            }
        }
    }

    private func popNext() -> Action? {
        lock.lock()
        defer { lock.unlock() }
        guard !state.stopped, !state.pending.isEmpty else {
            state.running = false
            return nil
        }
        let action = state.pending.removeFirst()
        switch action {
        case .write(let bytes): state.pendingUnits = max(0, state.pendingUnits - bytes.count)
        case .scroll(_, let count): state.pendingUnits = max(0, state.pendingUnits - count)
        }
        return action
    }

    private func execute(_ action: Action) -> Bool {
        switch action {
        case .write(let bytes):
            return runProcess(arguments: Self.actionArguments(
                sessionName: sessionName,
                paneID: paneID,
                action: .write(bytes)
            ))
        case .scroll(let name, let count):
            for _ in 0..<count {
                guard runProcess(arguments: Self.actionArguments(
                    sessionName: sessionName,
                    paneID: paneID,
                    action: .scroll(name)
                )) else { return false }
            }
            return true
        }
    }

    private func runProcess(arguments: [String]) -> Bool {
        lock.lock()
        if state.stopped {
            lock.unlock()
            return true
        }
        lock.unlock()

        let process = Process()
        if let remoteDestination {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            let command = arguments.map(Self.shellQuote).joined(separator: " ")
            process.arguments = [
                "-T", "-o", "EscapeChar=none", "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10", "--", remoteDestination,
                "zellij \(command)",
            ]
        } else {
            process.executableURL = URL(fileURLWithPath: zellijExecutablePath)
            process.arguments = arguments
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) {
                _, override in override
            }
        }

        lock.lock()
        guard !state.stopped else {
            lock.unlock()
            return true
        }
        state.currentProcess = process
        lock.unlock()
        defer {
            lock.lock()
            if state.currentProcess === process { state.currentProcess = nil }
            lock.unlock()
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            lock.lock()
            let stopped = state.stopped
            lock.unlock()
            return stopped
        }
        lock.lock()
        let stopped = state.stopped
        lock.unlock()
        return stopped || process.terminationStatus == 0
    }

    private func reportFailure(_ reason: String) {
        lock.lock()
        guard !state.failureReported, !state.stopped else {
            lock.unlock()
            return
        }
        state.failureReported = true
        lock.unlock()
        onFailure(reason)
    }

    private enum ActionArguments {
        case write([UInt8])
        case scroll(String)
    }

    private static func actionArguments(
        sessionName: String,
        paneID: String,
        action: ActionArguments
    ) -> [String] {
        var arguments = ["--session", sessionName, "action"]
        switch action {
        case .write(let bytes):
            arguments += ["write", "--pane-id", paneID]
            arguments += bytes.map(String.init)
        case .scroll(let name):
            arguments += [name, "--pane-id", paneID]
        }
        return arguments
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
