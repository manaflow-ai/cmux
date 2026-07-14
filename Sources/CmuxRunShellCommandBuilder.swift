import Foundation

enum CmuxRunShellCommandBuilder {
    static func launchCommand(for command: String) -> String {
        "/bin/zsh -lc \(shellQuote(command))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
