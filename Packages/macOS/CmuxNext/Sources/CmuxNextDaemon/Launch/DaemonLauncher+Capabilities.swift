import Foundation
import os

/// What the configured cmux-tui binary accepts before it runs an owner.
/// `server ensure` options are not negotiated over the socket (no owner
/// exists yet), so the launcher reads the binary's own `--help`, which
/// lists every start option it knows.
extension DaemonLauncher {
    static let reapGraceOption = "--terminal-reap-grace-seconds"

    /// True when the binary's `--help` lists `--terminal-reap-grace-seconds`.
    /// False when it does not, or when the probe fails: an owner without
    /// the grace never reaps (a closed tab's terminal lives on), which is
    /// better than an app that cannot start its daemon at all.
    func supportsReapGrace() async -> Bool {
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(executable: configuration.binary, arguments: ["--help"],
                                                 environment: nil, timeout: .seconds(5), clock: clock)
        } catch {
            Self.capabilityLogger.error("cmux-tui --help failed (\(String(describing: error), privacy: .public)); starting the owner without a reap grace")
            return false
        }
        let supported = result.status == 0 && Self.listsReapGrace(String(decoding: result.stdout, as: UTF8.self))
        if !supported {
            Self.capabilityLogger.notice("cmux-tui does not list \(Self.reapGraceOption, privacy: .public); starting the owner without a reap grace")
        }
        return supported
    }

    static func listsReapGrace(_ help: String) -> Bool {
        help.split(whereSeparator: \.isNewline).contains { line in
            line.split(whereSeparator: \.isWhitespace).first.map(String.init) == reapGraceOption
        }
    }

    static let capabilityLogger = Logger(subsystem: "com.cmuxterm.next", category: "daemon")
}
