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
