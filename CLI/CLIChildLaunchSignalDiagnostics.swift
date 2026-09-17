import Darwin
import Foundation

/// Diagnostics for the signal state a CLI-exec'd child is about to inherit.
///
/// `execve` preserves the calling thread's signal mask and every SIG_IGN
/// disposition into the new image. CLI command handlers run on Swift
/// concurrency cooperative-pool threads, which carry a nearly full signal
/// mask (0xFBFEE027 observed on macOS 26), so an agent resumed through
/// `cmux restore`/`cmux fork` can start with SIGWINCH blocked and never see
/// a resize again (https://github.com/manaflow-ai/cmux/issues/12681).
///
/// One line per exec attempt is appended to the diagnostics file so a
/// dogfood build can prove, in situ, which mask a child was launched with.
/// Opt-in via CMUX_EXEC_DIAG_FILE; DEBUG builds default to
/// /tmp/cmux-exec-diag.log so tagged dev builds always capture it.
enum CLIChildLaunchSignalDiagnostics {
    static let interestingSignals: [(name: String, number: Int32)] = [
        ("WINCH", SIGWINCH),
        ("PIPE", SIGPIPE),
        ("TTOU", SIGTTOU),
        ("TTIN", SIGTTIN),
        ("INT", SIGINT),
        ("TERM", SIGTERM),
        ("HUP", SIGHUP),
    ]

    static func diagnosticsFilePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let explicit = environment["CMUX_EXEC_DIAG_FILE"], !explicit.isEmpty {
            return explicit
        }
#if DEBUG
        return "/tmp/cmux-exec-diag.log"
#else
        return nil
#endif
    }

    static func currentThreadBlockedMask() -> UInt32 {
        var set = sigset_t()
        pthread_sigmask(SIG_BLOCK, nil, &set)
        return UInt32(set)
    }

    static func isBlocked(_ signal: Int32, inMask mask: UInt32) -> Bool {
        signal > 0 && signal <= 32 && (mask & (1 << UInt32(signal - 1))) != 0
    }

    static func isIgnored(_ signal: Int32) -> Bool {
        var action = sigaction()
        guard sigaction(signal, nil, &action) == 0 else { return false }
        return withUnsafeBytes(of: action.__sigaction_u) { raw in
            raw.load(as: UInt.self) == unsafeBitCast(SIG_IGN, to: UInt.self)
        }
    }

    /// Formats the one-line record. Split from `log` so it stays testable
    /// without touching the filesystem.
    static func record(context: String, target: String, mask: UInt32) -> String {
        let blocked = interestingSignals
            .filter { isBlocked($0.number, inMask: mask) }
            .map(\.name)
            .joined(separator: ",")
        let ignored = interestingSignals
            .filter { isIgnored($0.number) }
            .map(\.name)
            .joined(separator: ",")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return "\(timestamp) pid=\(getpid()) context=\(context) target=\(target) "
            + String(format: "mask=%#010x", mask)
            + " blocked=[\(blocked)] ignored=[\(ignored)]"
    }

    /// Appends the pre-exec signal-state record for `context` (which exec
    /// site) and `target` (the executable about to be exec'd).
    static func log(context: String, target: String) {
        guard let path = diagnosticsFilePath() else { return }
        let line = record(context: context, target: target, mask: currentThreadBlockedMask()) + "\n"
        guard let data = line.data(using: .utf8) else { return }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = write(fd, base, raw.count)
        }
    }
}
