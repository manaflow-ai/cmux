import Foundation

struct SudoExecutionCommand: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL
    let outputURL: URL
    let standardInput: Data?
    let standardInputReadyMarker: Data?

    init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        outputURL: URL,
        standardInput: Data? = nil,
        standardInputReadyMarker: Data? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.outputURL = outputURL
        self.standardInput = standardInput
        self.standardInputReadyMarker = standardInputReadyMarker
    }

    static func sudo(
        approvedScriptURL: URL,
        reviewedScript: Data,
        currentDirectoryURL: URL,
        outputURL: URL
    ) -> SudoExecutionCommand {
        let transport = SudoReviewedScriptTransport(
            reviewedScript: reviewedScript,
            approvedScriptURL: approvedScriptURL
        )
        return SudoExecutionCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/script"),
            arguments: [
                "/usr/bin/script",
                "-q",
                "/dev/null",
                "/usr/bin/sudo",
                "-k",
                "-p",
                SudoAuthenticationOutputDetector.passwordPrompt,
            ] + transport.shellArguments,
            currentDirectoryURL: currentDirectoryURL,
            outputURL: outputURL,
            standardInput: reviewedScript,
            standardInputReadyMarker: Data(SudoReviewedScriptTransport.readinessMarker.utf8)
        )
    }
}
