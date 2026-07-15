import Foundation

struct CmuxRunShellCommandBuilder {
    private static let directScriptDecoder =
        "eval\t\"$(printf\t'%s'\t\"$1\"|/usr/bin/base64\t-D)\""

    let command: String
    let workingDirectory: String
    let approvedIdentity: CmuxRunWorkingDirectoryIdentity

    var launchCommand: String {
        let script = """
        builtin cd -- \(shellQuote(workingDirectory)) || builtin exit -- $?
        [[ "$(command /usr/bin/stat -f '%d:%i' .)" == \(shellQuote(approvedIdentity.shellToken)) ]] || builtin exit 125
        \(command)
        """
        let encodedScript = Data(script.utf8).base64EncodedString()
        return "direct:/bin/zsh -dflc \(Self.directScriptDecoder) cmux-run \(encodedScript)"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
