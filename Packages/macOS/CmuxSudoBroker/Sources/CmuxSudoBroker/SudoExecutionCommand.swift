import Foundation

struct SudoExecutionCommand: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL
    let outputURL: URL
    let approvedScriptURL: URL?
    let standardInput: Data?
    let standardInputReadyMarker: Data?
    let controlMarkers: SudoExecutionControlMarkers
    let expectedDirectoryIdentity: SudoDirectoryIdentity?

    init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        outputURL: URL,
        approvedScriptURL: URL? = nil,
        standardInput: Data? = nil,
        standardInputReadyMarker: Data? = nil,
        controlMarkers: SudoExecutionControlMarkers = SudoExecutionControlMarkers(),
        expectedDirectoryIdentity: SudoDirectoryIdentity? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.outputURL = outputURL
        self.approvedScriptURL = approvedScriptURL
        self.standardInput = standardInput
        self.standardInputReadyMarker = standardInputReadyMarker
        self.controlMarkers = controlMarkers
        self.expectedDirectoryIdentity = expectedDirectoryIdentity
    }

    static func sudo(
        approvedScriptURL: URL,
        reviewedScript: Data,
        privilegedHelperExecutableURL: URL,
        deadline: Date,
        currentDirectoryURL: URL,
        outputURL: URL,
        directoryIdentity: SudoDirectoryIdentity? = nil
    ) -> SudoExecutionCommand {
        let controlMarkers = SudoExecutionControlMarkers()
        let transport = SudoReviewedScriptTransport(
            reviewedScript: reviewedScript,
            approvedScriptURL: approvedScriptURL,
            privilegedHelperExecutableURL: privilegedHelperExecutableURL,
            deadline: deadline,
            controlToken: controlMarkers.token
        )
        return SudoExecutionCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/script"),
            arguments: [
                "/usr/bin/script",
                "-q",
                "/dev/null",
                "/usr/bin/sudo",
                "-k",
                "-S",
                "-p",
                SudoAuthenticationOutputDetector.passwordPrompt,
            ] + transport.shellArguments,
            currentDirectoryURL: currentDirectoryURL,
            outputURL: outputURL,
            approvedScriptURL: approvedScriptURL,
            standardInput: reviewedScript,
            standardInputReadyMarker: controlMarkers.inputReady,
            controlMarkers: controlMarkers,
            expectedDirectoryIdentity: directoryIdentity
        )
    }
}
