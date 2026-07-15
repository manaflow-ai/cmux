import Foundation

struct CmuxRunShellCommandBuilder {
    let command: String
    let workingDirectory: String
    let approvedIdentity: CmuxRunWorkingDirectoryIdentity

    var launchCommand: String {
        let script = """
        builtin cd -- \(shellQuote(workingDirectory)) || exit $?
        cmux_directory_identity="$(command /usr/bin/stat -f '%d:%i' .)" || exit $?
        [[ "$cmux_directory_identity" == \(shellQuote(approvedIdentity.shellToken)) ]] || exit 125
        \(command)
        """
        return "/bin/zsh -lc \(shellQuote(script))"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
