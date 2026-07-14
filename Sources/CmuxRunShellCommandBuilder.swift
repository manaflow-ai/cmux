import Foundation

enum CmuxRunShellCommandBuilder {
    static func launchCommand(for command: String, workingDirectory: String) -> String {
        let script = "cd -- \(shellQuote(workingDirectory)) || exit $?\n\(command)"
        return "/bin/zsh -lc \(shellQuote(script))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
