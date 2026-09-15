import Darwin
import Foundation

/// Resolves terminal working-directory candidates and live local process state.
struct TerminalWorkingDirectoryResolver {
    typealias LiveDirectoryProvider = @MainActor (TerminalPanel) -> String?

    private let liveDirectoryProvider: LiveDirectoryProvider

    init(liveDirectoryProvider: LiveDirectoryProvider? = nil) {
        if let liveDirectoryProvider {
            self.liveDirectoryProvider = liveDirectoryProvider
        } else {
            self.liveDirectoryProvider = { terminal in
                guard let pid = terminal.surface.foregroundProcessID() else { return nil }
                return Self.processCurrentWorkingDirectory(pid: Int32(clamping: pid))
            }
        }
    }

    @MainActor func liveForegroundProcessWorkingDirectory(for terminal: TerminalPanel) -> String? {
        Self.normalized(liveDirectoryProvider(terminal))
    }

    nonisolated static func firstAvailable(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            if let candidate = normalized(candidate) {
                return candidate
            }
        }
        return nil
    }

    nonisolated static func normalized(_ workingDirectory: String?) -> String? {
        let trimmed = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Chooses between a terminal's shell-reported cwd and its foreground
    /// job's cwd, preferring the foreground job.
    ///
    /// A process started from a different directory than the prompt — most
    /// notably `claude --worktree`, which runs the agent inside a git worktree
    /// while the prompt shell stays in the repository root — makes the shell's
    /// OSC 7 report stale for "the directory being worked in".
    ///
    /// The foreground directory wins only when it resolves to a genuinely
    /// different directory: at the prompt the two match, and returning the
    /// shell's own reported path preserves a symlinked cwd verbatim instead of
    /// swapping in its realpath. An empty `shellDirectory` means directory
    /// provenance was deliberately withheld for that pane, so no foreground
    /// value may resurrect one.
    nonisolated static func preferringForegroundDirectory(
        shellDirectory: String,
        foregroundDirectory: String?
    ) -> String {
        guard !shellDirectory.isEmpty,
              let foreground = normalized(foregroundDirectory),
              foreground != shellDirectory else {
            return shellDirectory
        }
        let foregroundReal = URL(fileURLWithPath: foreground).resolvingSymlinksInPath().path
        let shellReal = URL(fileURLWithPath: shellDirectory).resolvingSymlinksInPath().path
        return foregroundReal == shellReal ? shellDirectory : foreground
    }

    /// The current working directory of `pid` via
    /// `proc_pidinfo(PROC_PIDVNODEPATHINFO)`, or nil when the process is gone
    /// or unreadable.
    nonisolated static func processCurrentWorkingDirectory(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let expectedSize = MemoryLayout<proc_vnodepathinfo>.size
        let size = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(expectedSize))
        guard size == expectedSize else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { rawBuffer -> String in
            let endIndex = rawBuffer.firstIndex(of: 0) ?? rawBuffer.endIndex
            return String(decoding: rawBuffer[..<endIndex], as: UTF8.self)
        }
        return normalized(path)
    }
}
