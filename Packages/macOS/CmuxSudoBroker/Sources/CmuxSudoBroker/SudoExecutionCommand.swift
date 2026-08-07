import Foundation

struct SudoExecutionCommand: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL
    let outputURL: URL

    static func sudo(
        approvedScriptURL: URL,
        currentDirectoryURL: URL,
        outputURL: URL
    ) -> SudoExecutionCommand {
        SudoExecutionCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/script"),
            arguments: [
                "/usr/bin/script",
                "-q",
                "/dev/null",
                "/usr/bin/sudo",
                "-k",
                "/bin/bash",
                approvedScriptURL.path,
            ],
            currentDirectoryURL: currentDirectoryURL,
            outputURL: outputURL
        )
    }
}
