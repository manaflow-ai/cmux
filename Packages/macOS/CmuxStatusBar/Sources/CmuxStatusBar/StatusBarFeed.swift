import CmuxFoundation
import Foundation
public import Observation

/// Runs `statusBar.command` and publishes the last line it printed. Writing a
/// newline to its stdin asks it to refresh. When it exits it is started again
/// after ``relaunchDelay``, so a command that prints one line and quits works
/// as a poll.
///
/// The app owns one feed and hands it to every window, so the command runs
/// once however many windows are open.
@MainActor
@Observable
public final class StatusBarFeed {
    /// What the bar shows.
    public enum Content: Equatable, Sendable {
        /// No command is set, or it has not printed a line yet.
        case hidden
        /// The newest line, grouped into link segments.
        case line([StatusBarSegment])
        /// The last run exited, or failed to start, without printing a line.
        case silentExit
    }

    /// The bar's current content.
    public private(set) var content: Content = .hidden

    /// Wait between the command exiting and its next start.
    public let relaunchDelay: Duration

    @ObservationIgnored private let clock: any StatusBarRelaunchClock
    @ObservationIgnored private var command = ""
    @ObservationIgnored private var supervisor: Task<Void, Never>?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?

    /// Creates an idle feed; nothing runs until ``run(_:)`` gets a command.
    public init(
        clock: any StatusBarRelaunchClock = SystemStatusBarRelaunchClock(),
        relaunchDelay: Duration = .seconds(10)
    ) {
        self.clock = clock
        self.relaunchDelay = relaunchDelay
    }

    /// Starts `newCommand` in place of whatever ran before. Empty stops it and
    /// hides the bar. The same command again is ignored.
    public func run(_ newCommand: String) {
        guard newCommand != command else { return }
        command = newCommand
        supervisor?.cancel()
        supervisor = nil
        // Closing stdin is what stops a program that ignores SIGTERM in a child.
        try? input?.close()
        process?.terminate()
        input = nil
        process = nil
        content = .hidden
        guard !newCommand.isEmpty else { return }
        supervisor = Task { [weak self] in
            await self?.supervise(newCommand)
        }
    }

    /// Writes a newline to the command's stdin as a refresh request.
    public func requestRefresh() {
        try? input?.write(contentsOf: Data("\n".utf8))
    }

    private func supervise(_ command: String) async {
        while !Task.isCancelled {
            await runOnce(command)
            guard !Task.isCancelled else { return }
            do {
                try await clock.sleep(for: relaunchDelay)
            } catch {
                return
            }
        }
    }

    /// Runs the command to completion: until its output ends and it exits.
    private func runOnce(_ command: String) async {
        let launched = Process()
        launched.executableURL = URL(fileURLWithPath: "/bin/sh")
        launched.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        // Apps opened from Finder get launchd's PATH, which has no Homebrew.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        launched.environment = environment

        let stdout = Pipe()
        let stdin = Pipe()
        launched.standardOutput = stdout
        launched.standardInput = stdin
        launched.standardError = FileHandle.nullDevice

        let (output, outputContinuation) = AsyncStream<Data>.makeStream()
        let (exit, exitContinuation) = AsyncStream<Void>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let chunk):
                outputContinuation.yield(chunk)
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
                outputContinuation.finish()
            }
        }
        launched.terminationHandler = { _ in exitContinuation.finish() }

        do {
            try launched.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            content = .silentExit
            return
        }
        process = launched
        input = stdin.fileHandleForWriting
        defer {
            // A newer run may already own these after a command change.
            if process === launched {
                process = nil
                input = nil
            }
        }

        var reader = StatusBarLineReader()
        var printed = false
        // The stream delivers chunks in the order they were read, and only
        // ends once the last one is in, so the exit check below sees them all.
        for await chunk in output {
            // Chunks already buffered still arrive after a cancel.
            guard !Task.isCancelled else { return }
            if let line = reader.append(chunk) {
                show(line)
                printed = true
            }
        }
        guard !Task.isCancelled else { return }
        if let line = reader.finish() {
            show(line)
            printed = true
        }
        if !printed { content = .silentExit }
        for await _ in exit {}
    }

    private func show(_ line: String) {
        content = .line(StatusBarSegment.segments(of: StatusBarRun.parse(line)))
    }
}
