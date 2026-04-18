import Foundation
import Darwin

/// Detects AI coding agent processes running in a terminal and extracts
/// their task descriptions from command-line arguments.
enum TerminalAgentDetector {

    struct DetectedAgent {
        let executableName: String   // e.g. "claude", "codex"
        let taskDescription: String? // extracted from process args
        let pid: Int32
    }

    /// Known agent binary names (matched case-insensitively against ucomm from ps).
    static let knownAgentBinaries: Set<String> = [
        "claude", "codex", "gemini", "opencode", "aider", "ft-claude",
    ]

    /// Quick check whether a terminal title matches a known agent binary name.
    static func isKnownAgentName(_ name: String) -> Bool {
        knownAgentBinaries.contains(name.lowercased())
    }

    /// Detect a foreground agent process on the given TTY device.
    /// Returns `nil` if no known agent is in the foreground process group.
    static func detect(forTTY ttyName: String) -> DetectedAgent? {
        let snapshots = processSnapshots(forTTY: ttyName)
        // Find foreground processes (pgid == tpgid) that are known agents
        let foreground = snapshots.filter { $0.pgid == $0.tpgid }
        guard let match = foreground.first(where: { knownAgentBinaries.contains($0.executableName) }) else {
            return nil
        }
        let args = commandLineArguments(forPID: match.pid)
        let task = args.flatMap { extractTaskDescription(from: $0, agent: match.executableName) }
        return DetectedAgent(executableName: match.executableName, taskDescription: task, pid: match.pid)
    }

    // MARK: - Process enumeration (same pattern as TerminalSSHSessionDetector)

    private struct ProcessSnapshot {
        let pid: Int32
        let pgid: Int32
        let tpgid: Int32
        let executableName: String
    }

    private static let psPath = "/bin/ps"

    private static func processSnapshots(forTTY ttyName: String) -> [ProcessSnapshot] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: psPath)
        process.arguments = ["-ww", "-t", ttyName, "-o", "pid=,pgid=,tpgid=,ucomm="]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return [] }

        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let pgid = Int32(parts[1]),
                  let tpgid = Int32(parts[2]) else { return nil }
            return ProcessSnapshot(
                pid: pid, pgid: pgid, tpgid: tpgid,
                executableName: String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        }
    }

    // MARK: - Command-line argument reading (KERN_PROCARGS2)

    private static func commandLineArguments(forPID pid: Int32) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        let ok = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &size, nil, 0) == 0
        }
        guard ok else { return nil }
        return parseKernProcArgs(Array(buffer.prefix(Int(size))))
    }

    private static func parseKernProcArgs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }
        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { $0.copyBytes(from: bytes.prefix(4)) }
        let argc = Int(Int32(littleEndian: argcRaw))
        guard argc > 0 else { return nil }

        // Skip past argc + executable path + padding nulls
        var i = 4
        while i < bytes.count, bytes[i] != 0 { i += 1 }
        while i < bytes.count, bytes[i] == 0 { i += 1 }

        var args: [String] = []
        while i < bytes.count, args.count < argc {
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            guard let arg = String(bytes: bytes[start..<i], encoding: .utf8) else { return nil }
            args.append(arg)
            while i < bytes.count, bytes[i] == 0 { i += 1 }
        }
        return args.count == argc ? args : nil
    }

    // MARK: - Task description extraction

    /// Extract a human-readable task description from the agent's command-line arguments.
    /// Returns `nil` if no meaningful description can be determined (e.g. interactive mode).
    private static func extractTaskDescription(from args: [String], agent: String) -> String? {
        // args[0] is the executable path; positional args start from args[1..]
        guard args.count > 1 else { return nil }
        let tail = Array(args.dropFirst())

        // For "codex exec <prompt>" and "opencode run <prompt>", skip the subcommand
        let positional: [String]
        if (agent == "codex" || agent == "opencode"), tail.count > 1 {
            let sub = tail[0].lowercased()
            if sub == "exec" || sub == "run" {
                positional = Array(tail.dropFirst())
            } else {
                positional = tail
            }
        } else {
            positional = tail
        }

        // Find first non-flag argument (doesn't start with -)
        // Also skip known flag values (the argument after a flag that takes a value)
        let flagsWithValue: Set<String> = [
            "--model", "-m", "--settings", "--agent", "-c",
            "--append-system-prompt", "--append-system-prompt-file",
            "--system-prompt", "--system-prompt-file",
            "--prompt-file",
        ]

        var skipNext = false
        for arg in positional {
            if skipNext { skipNext = false; continue }
            if arg.hasPrefix("-") {
                if flagsWithValue.contains(arg) { skipNext = true }
                continue
            }
            // Found a positional argument — this is likely the prompt/task
            let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Truncate to keep tab names readable
            if trimmed.count > 60 {
                return String(trimmed.prefix(57)) + "..."
            }
            return trimmed
        }
        return nil
    }
}
