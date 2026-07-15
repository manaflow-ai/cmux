import Foundation

struct CmuxRunShellCommandBuilder {
    let command: String
    let workingDirectory: String
    let approvedIdentity: CmuxRunWorkingDirectoryIdentity

    var launchCommand: String {
        let script = """
        builtin cd -- \(shellQuote(workingDirectory)) || builtin exit -- $?
        [[ "$(command /usr/bin/stat -f '%d:%i' .)" == \(shellQuote(approvedIdentity.shellToken)) ]] || builtin exit 125
        \(command)
        """
        return "/bin/zsh -dflc \(shellQuote(script))"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
