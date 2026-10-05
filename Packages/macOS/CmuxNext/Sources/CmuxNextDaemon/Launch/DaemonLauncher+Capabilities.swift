import Foundation
import os

/// What the configured cmux-tui binary accepts before it runs an owner.
/// `server ensure` options are not negotiated over the socket (no owner
/// exists yet), so the launcher reads the binary's startup help. Older
/// clients put those options in root help; current clients use `help start`.
extension DaemonLauncher {
    static let reapGraceOption = "--terminal-reap-grace-seconds"

    /// True when the binary's help lists `--terminal-reap-grace-seconds`.
    /// False when it does not, or when the probe fails: an owner without
    /// the grace never reaps (a closed tab's terminal lives on), which is
    /// better than an app that cannot start its daemon at all.
    func supportsReapGrace() async -> Bool {
        for arguments in [["--help"], ["help", "start"]] {
            do {
                let result = try await ProcessRunner.run(executable: configuration.binary, arguments: arguments,
                                                         environment: nil, timeout: .seconds(5), clock: clock)
                if result.status == 0 && Self.listsReapGrace(String(decoding: result.stdout, as: UTF8.self)) {
                    return true
                }
            } catch {
                Self.capabilityLogger.error("cmux-tui \(arguments.joined(separator: " "), privacy: .public) failed (\(String(describing: error), privacy: .public))")
            }
        }
        Self.capabilityLogger.notice("cmux-tui does not list \(Self.reapGraceOption, privacy: .public); starting the owner without a reap grace")
        return false
    }

    static func listsReapGrace(_ help: String) -> Bool {
        help.split(whereSeparator: \.isNewline).contains { line in
            line.split(whereSeparator: \.isWhitespace).first.map(String.init) == reapGraceOption
        }
    }

    static let capabilityLogger = Logger(subsystem: "com.cmuxterm.next", category: "daemon")
}
