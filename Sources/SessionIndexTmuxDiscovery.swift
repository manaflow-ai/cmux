import Foundation

/// Bridges `Process` callback APIs into an async tmux discovery command.
/// `terminationHandler`, `readabilityHandler`, and `onCancel` are synchronous
/// callbacks that cannot hop through an actor before deciding whether to resume
/// the continuation, so this keeps the small shared state behind `lock`.
private final class SessionIndexTmuxCommandState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let stdoutHandle: FileHandle
    private var output = Data()
    private var continuation: CheckedContinuation<String?, Never>?
    private var completed = false
    private var cancelled = false

    init(process: Process, stdoutHandle: FileHandle) {
        self.process = process
        self.stdoutHandle = stdoutHandle
    }

    func start(continuation: CheckedContinuation<String?, Never>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        guard !cancelled else {
            completed = true
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        lock.unlock()

        stdoutHandle.readabilityHandler = { [weak self] handle in
            self?.readAvailableData(from: handle)
        }
        process.terminationHandler = { [weak self] process in
            self?.finish(terminationStatus: process.terminationStatus)
        }

        lock.lock()
        guard !completed && !cancelled else {
            lock.unlock()
            finish(result: nil)
            return
        }
        do {
            try process.run()
            lock.unlock()
        } catch {
            lock.unlock()
            finish(result: nil)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()

        if process.isRunning {
            process.terminate()
        } else {
            finish(result: nil)
        }
    }

    private func readAvailableData(from handle: FileHandle) {
        let data = handle.availableData
        guard !data.isEmpty else { return }
        lock.lock()
        output.append(data)
        lock.unlock()
    }

    private func finish(terminationStatus: Int32) {
        stdoutHandle.readabilityHandler = nil
        let trailing = stdoutHandle.availableData
        let data: Data
        let continuation: CheckedContinuation<String?, Never>?
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        if !trailing.isEmpty {
            output.append(trailing)
        }
        data = output
        completed = true
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        process.terminationHandler = nil
        continuation?.resume(
            returning: terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
        )
    }

    private func finish(result: String?) {
        let continuation: CheckedContinuation<String?, Never>?
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        stdoutHandle.readabilityHandler = nil
        process.terminationHandler = nil
        continuation?.resume(returning: result)
    }
}

enum SessionIndexTmuxDiscovery {
    private struct TmuxSessionDescriptor: Equatable {
        let name: String
        let windowCount: Int
        let paneCount: Int
        let attachedCount: Int
        let createdAt: Date
    }

    nonisolated private static let listSeparator = "\u{1F}"

    nonisolated static func loadEntries(
        needle: String,
        offset: Int,
        limit: Int
    ) async -> [SessionEntry] {
        guard let executablePath = resolvedExecutablePath(),
              let sessionsOutput = await runCommand(
                executablePath: executablePath,
                arguments: [
                    "list-sessions",
                    "-F",
                    "#{session_name}\(listSeparator)#{session_windows}\(listSeparator)#{session_attached}\(listSeparator)#{session_created}"
                ]
              ) else {
            return []
        }
        let windowsOutput = await runCommand(
            executablePath: executablePath,
            arguments: [
                "list-windows",
                "-a",
                "-F",
                "#{session_name}\(listSeparator)#{window_panes}"
            ]
        ) ?? ""
        let entries = entries(
            sessionsOutput: sessionsOutput,
            windowsOutput: windowsOutput,
            executablePath: executablePath,
            now: Date.now
        )
        let filtered = needle.isEmpty
            ? entries
            : entries.filter { entry in
                entry.displayTitle.range(of: needle, options: [.caseInsensitive, .literal]) != nil
                    || entry.sessionId.range(of: needle, options: [.caseInsensitive, .literal]) != nil
            }
        return Array(filtered.dropFirst(offset).prefix(limit))
    }

    nonisolated static func runCommandForTesting(
        executablePath: String,
        arguments: [String]
    ) async -> String? {
        await runCommand(executablePath: executablePath, arguments: arguments)
    }

    nonisolated static func entriesForTesting(
        sessionsOutput: String,
        windowsOutput: String,
        executablePath: String = "tmux",
        now: Date
    ) -> [SessionEntry] {
        entries(
            sessionsOutput: sessionsOutput,
            windowsOutput: windowsOutput,
            executablePath: executablePath,
            now: now
        )
    }

    nonisolated private static func resolvedExecutablePath() -> String? {
        let fileManager = FileManager.default
        var candidates: [String] = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        candidates.append(contentsOf: pathEntries.map { ($0 as NSString).appendingPathComponent("tmux") })

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    nonisolated private static func runCommand(
        executablePath: String,
        arguments: [String]
    ) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        if let nullDevice = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardError = nullDevice
        }

        let commandState = SessionIndexTmuxCommandState(
            process: process,
            stdoutHandle: stdout.fileHandleForReading
        )
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                return nil
            }
            return await withCheckedContinuation { continuation in
                commandState.start(continuation: continuation)
            }
        } onCancel: {
            commandState.cancel()
        }
    }

    nonisolated private static func entries(
        sessionsOutput: String,
        windowsOutput: String,
        executablePath: String,
        now: Date
    ) -> [SessionEntry] {
        parseSessions(
            sessionsOutput: sessionsOutput,
            windowsOutput: windowsOutput,
            now: now
        )
        .sorted { lhs, rhs in
            if lhs.attachedCount != rhs.attachedCount {
                return lhs.attachedCount > rhs.attachedCount
            }
            return lhs.createdAt > rhs.createdAt
        }
        .map { descriptor in
            let attachCommand = attachCommand(
                executablePath: executablePath,
                sessionName: descriptor.name
            )
            return SessionEntry(
                id: "tmux:\(descriptor.name)",
                agent: .tmux,
                sessionId: descriptor.name,
                title: sessionTitle(descriptor),
                cwd: nil,
                gitBranch: nil,
                pullRequest: nil,
                modified: descriptor.createdAt,
                fileURL: nil,
                specifics: .tmux(
                    attachCommand: attachCommand,
                    attachedCount: descriptor.attachedCount
                )
            )
        }
    }

    nonisolated private static func parseSessions(
        sessionsOutput: String,
        windowsOutput: String,
        now: Date
    ) -> [TmuxSessionDescriptor] {
        var paneCountsBySession: [String: Int] = [:]
        for line in windowsOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: Character(listSeparator), omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let name = String(fields[0])
            let panes = Int(String(fields[1])) ?? 0
            paneCountsBySession[name, default: 0] += panes
        }

        return sessionsOutput.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: Character(listSeparator), omittingEmptySubsequences: false)
            guard fields.count >= 4 else { return nil }
            let name = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let windowCount = max(Int(String(fields[1])) ?? 0, 0)
            let attachedCount = max(Int(String(fields[2])) ?? 0, 0)
            let createdSeconds = TimeInterval(String(fields[3])) ?? now.timeIntervalSince1970
            let paneCount = paneCountsBySession[name].map { max($0, windowCount) } ?? windowCount
            return TmuxSessionDescriptor(
                name: name,
                windowCount: windowCount,
                paneCount: paneCount,
                attachedCount: attachedCount,
                createdAt: Date(timeIntervalSince1970: createdSeconds)
            )
        }
    }

    nonisolated private static func attachCommand(executablePath: String, sessionName: String) -> String {
        [executablePath, "attach", "-t", sessionName]
            .map(TerminalStartupShellQuoting.singleQuoted)
            .joined(separator: " ")
    }

    nonisolated private static func sessionTitle(_ descriptor: TmuxSessionDescriptor) -> String {
        switch (descriptor.windowCount == 1, descriptor.paneCount == 1) {
        case (true, true):
            return String.localizedStringWithFormat(
                String(localized: "sessionIndex.tmux.sessionTitle.oneWindowOnePane", defaultValue: "%@ · 1 window, 1 pane"),
                descriptor.name
            )
        case (true, false):
            return String.localizedStringWithFormat(
                String(localized: "sessionIndex.tmux.sessionTitle.oneWindowManyPanes", defaultValue: "%@ · 1 window, %d panes"),
                descriptor.name,
                descriptor.paneCount
            )
        case (false, true):
            return String.localizedStringWithFormat(
                String(localized: "sessionIndex.tmux.sessionTitle.manyWindowsOnePane", defaultValue: "%@ · %d windows, 1 pane"),
                descriptor.name,
                descriptor.windowCount
            )
        case (false, false):
            return String.localizedStringWithFormat(
                String(localized: "sessionIndex.tmux.sessionTitle.manyWindowsManyPanes", defaultValue: "%@ · %d windows, %d panes"),
                descriptor.name,
                descriptor.windowCount,
                descriptor.paneCount
            )
        }
    }
}
