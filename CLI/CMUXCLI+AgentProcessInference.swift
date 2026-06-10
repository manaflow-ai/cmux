import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Agent PID/process inference
extension CMUXCLI {
    func mergedNodeOptions(existing: String?, restoreModulePath: String) -> String {
        let requireOption = "--require=\(restoreModulePath)"
        let memoryOption = "--max-old-space-size=4096"
        let cleanedExisting = cleanedNodeOptions(existing)
        guard !cleanedExisting.isEmpty else {
            return "\(requireOption) \(memoryOption)"
        }
        return "\(requireOption) \(memoryOption) \(cleanedExisting)"
    }

    private func cleanedNodeOptions(_ existing: String?) -> String {
        let tokens = (existing ?? "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return "" }

        var filtered: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--max-old-space-size" {
                index += min(2, tokens.count - index)
                continue
            }
            if token.hasPrefix("--max-old-space-size=") {
                index += 1
                continue
            }
            filtered.append(token)
            index += 1
        }
        return filtered.joined(separator: " ")
    }

    func normalizedNodeOptionsForRestore(_ existing: String) -> String {
        let tokens = existing
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return "" }

        var normalized: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--max-old-space-size", index + 1 < tokens.count {
                normalized.append("--max-old-space-size=\(tokens[index + 1])")
                index += 2
                continue
            }
            normalized.append(token)
            index += 1
        }
        return normalized.joined(separator: " ")
    }

    // MARK: - Codex hooks

    /// The hooks.json content that cmux installs into ~/.codex/.
    /// Each hook calls `cmux hooks codex <event>` which gracefully no-ops
    /// when not running inside cmux. The command checks for cmux on PATH
    /// first so it silently succeeds even when cmux is not installed
    /// (e.g. user opened codex in a non-cmux terminal).

    // MARK: - Agent PID inference

    func inferredAgentPID() -> Int? {
        var candidate = getppid()
        var remainingWrapperSkips = 8

        while candidate > 1, remainingWrapperSkips > 0 {
            guard let processName = processName(for: candidate) else { break }
            if !agentHookWrapperProcessNames.contains(processName) {
                break
            }
            let next = parentPID(of: candidate)
            guard next > 1, next != candidate else { break }
            candidate = next
            remainingWrapperSkips -= 1
        }

        return candidate > 1 ? Int(candidate) : nil
    }

    func claudeAgentPID(from env: [String: String]) -> Int? {
        guard let raw = env["CMUX_CLAUDE_PID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let pid = Int(raw),
            pid > 0 else {
            return nil
        }
        return pid
    }

    func shouldSuppressNestedAgentVisibleMutations(
        currentAgentPID: Int?,
        nestedPromptEvent: Bool = false,
        transcriptSubagentSession: Bool = false,
        env: [String: String]
    ) -> Bool {
        if let override = normalizedHookValue(env["CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS"])?.lowercased(),
           Self.parseHookBoolean(override) == true {
            return true
        }

        guard subagentNotificationSuppressionEnabled(env: env) else {
            return false
        }

        if nestedPromptEvent {
            return true
        }

        if managedSubagentVisibleMutationSuppressionRequested(env: env) {
            return true
        }

        if transcriptSubagentSession {
            return true
        }

        guard let currentAgentPID, currentAgentPID > 1 else {
            return false
        }

        var candidate = pid_t(currentAgentPID)
        var agentProcessCount = 0
        var remainingAncestors = 32
        while candidate > 1, remainingAncestors > 0 {
            if nativeAgentProcessKind(for: candidate) != nil {
                agentProcessCount += 1
                if agentProcessCount >= 2 {
                    return true
                }
            }
            let next = parentPID(of: candidate)
            guard next > 1, next != candidate else {
                break
            }
            candidate = next
            remainingAncestors -= 1
        }
        return false
    }

    private func managedSubagentVisibleMutationSuppressionRequested(env: [String: String]) -> Bool {
        guard let raw = normalizedHookValue(env[managedSubagentEnvironmentKey]),
              let parsed = Self.parseHookBoolean(raw) else {
            return false
        }
        return parsed
    }

    func subagentNotificationSuppressionEnabled(env: [String: String]) -> Bool {
        if let raw = normalizedHookValue(env[suppressSubagentNotificationsEnvironmentKey]),
           let parsed = Self.parseHookBoolean(raw) {
            return parsed
        }
        for defaults in appDefaultsCandidates(env: env) {
            if defaults.object(forKey: suppressSubagentNotificationsDefaultsKey) != nil {
                return defaults.bool(forKey: suppressSubagentNotificationsDefaultsKey)
            }
        }
        return true
    }

    private func appDefaultsCandidates(env: [String: String]) -> [UserDefaults] {
        var candidates: [UserDefaults] = []
        if let bundleId = normalizedHookValue(env["CMUX_BUNDLE_ID"]),
           let defaults = UserDefaults(suiteName: bundleId) {
            candidates.append(defaults)
        }
        candidates.append(.standard)
        return candidates
    }

    private static func parseHookBoolean(_ rawValue: String) -> Bool? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "enabled":
            return true
        case "0", "false", "no", "off", "disabled":
            return false
        default:
            return nil
        }
    }

    private func nativeAgentProcessKind(for pid: pid_t) -> HookAgentProcessKind? {
        let name = processName(for: pid)
        if let kind = Self.nativeAgentProcessKind(processName: name, arguments: []) {
            return kind
        }

        let nameBase = Self.agentProcessBasename(name)
        if let nameBase, nameBase != "node", nameBase != "bun" {
            return nil
        }

        return Self.nativeAgentProcessKind(
            processName: name,
            arguments: processArguments(for: pid) ?? []
        )
    }

    private static func nativeAgentProcessKind(
        processName: String?,
        arguments: [String]
    ) -> HookAgentProcessKind? {
        let nameBase = agentProcessBasename(processName)
        let executableBase = agentProcessBasename(arguments.first)

        // Codex's npm/bun launcher leaves a node process above the native
        // Codex binary. That wrapper is part of the same launch, not a
        // parent agent, so only native Codex executables count. Claude Code
        // can run as a node script, so keep that as an agent process.
        if nameBase == "node" || nameBase == "bun" || executableBase == "node" || executableBase == "bun" {
            if arguments.dropFirst().contains(where: { argument in
                let lowered = argument.lowercased()
                return agentProcessBasename(argument) == "claude"
                    || lowered.contains("/.claude/")
                    || lowered.contains("/claude/versions/")
            }) {
                return .claude
            }
            return nil
        }

        let executable = arguments.first?.lowercased() ?? ""
        if nameBase == "codex" || executableBase == "codex" || executable.contains("/codex/codex") {
            return .codex
        }
        if nameBase == "claude" || executableBase == "claude" || executable.contains("/claude/versions/") {
            return .claude
        }
        return nil
    }

    private static func agentProcessBasename(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: value).lastPathComponent.lowercased()
    }

    private func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return -1
        }
        return info.kp_eproc.e_ppid
    }

    private func processName(for pid: pid_t) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "comm="]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: stdout.fileHandleForReading)
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: output).lastPathComponent.lowercased()
    }

    func processArguments(for pid: pid_t) -> [String]? {
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        var argMaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argMaxMib, UInt32(argMaxMib.count), &argMax, &argMaxSize, nil, 0) == 0,
              argMax > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let status = buffer.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, UInt32(mib.count), rawBuffer.baseAddress, &size, nil, 0)
        }
        guard status == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { argcBytes in
            for offset in 0..<MemoryLayout<Int32>.size {
                argcBytes[offset] = buffer[offset]
            }
        }
        guard argc > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 {
            index += 1
        }
        while index < size, buffer[index] == 0 {
            index += 1
        }

        var arguments: [String] = []
        for _ in 0..<argc {
            guard index < size else { break }
            let start = index
            while index < size, buffer[index] != 0 {
                index += 1
            }
            guard index > start else { break }
            if let value = String(bytes: buffer[start..<index], encoding: .utf8) {
                arguments.append(value)
            }
            while index < size, buffer[index] == 0 {
                index += 1
            }
        }

        return arguments.isEmpty ? nil : arguments
    }

}
