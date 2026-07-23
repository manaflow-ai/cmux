import CmuxTerminal
import Darwin
import Foundation

extension TerminalShellResolver {
    static func resolveCurrentUserShell(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shellsFileURL: URL = URL(fileURLWithPath: "/etc/shells")
    ) -> String? {
        TerminalShellResolver(isExecutable: FileManager.default.isExecutableFile(atPath:))
            .resolve(
                loginShell: currentUserDatabaseShell(),
                environmentShell: environment["SHELL"],
                declaredShells: declaredShells(at: shellsFileURL)
            )
    }

    private static func currentUserDatabaseShell() -> String? {
        guard let record = getpwuid(getuid()),
              let shell = record.pointee.pw_shell else {
            return nil
        }
        return String(cString: shell)
    }

    private static func declaredShells(at url: URL) -> [String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return contents.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let path = rawLine
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        }
    }
}
