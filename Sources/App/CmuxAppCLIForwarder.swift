import Darwin
import Foundation

nonisolated enum CmuxAppCLIForwarder {
    enum Decision: Equatable {
        case launchApp
        case forward(cliURL: URL, arguments: [String])
        case fail(message: String, exitCode: Int32)
    }

    static func forwardIfNeeded() {
        switch decision() {
        case .launchApp:
            return
        case .forward(let cliURL, let arguments):
            exec(cliURL: cliURL, arguments: arguments)
        case .fail(let message, let exitCode):
            writeError(message)
            Darwin.exit(exitCode)
        }
    }

    static func decision(
        arguments: [String] = CommandLine.arguments,
        bundledCLIURL: URL? = CmuxBundledCLI.url(),
        expectedBundledCLIPath: String = CmuxBundledCLI.expectedPath(),
        fileManager: FileManager = .default
    ) -> Decision {
        guard shouldForward(arguments: arguments) else {
            return .launchApp
        }

        guard let cliURL = bundledCLIURL?.standardizedFileURL else {
            return .fail(
                message: String(
                    format: String(localized: "cli.forward.error.bundledMissing", defaultValue: "Bundled cmux CLI was not found at %@."),
                    expectedBundledCLIPath
                ),
                exitCode: 127
            )
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: cliURL.path, isDirectory: &isDirectory) else {
            return .fail(
                message: String(
                    format: String(localized: "cli.forward.error.bundledMissing", defaultValue: "Bundled cmux CLI was not found at %@."),
                    cliURL.path
                ),
                exitCode: 127
            )
        }
        guard !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: cliURL.path) else {
            return .fail(
                message: String(
                    format: String(localized: "cli.forward.error.bundledNotExecutable", defaultValue: "Bundled cmux CLI is not executable at %@."),
                    cliURL.path
                ),
                exitCode: 126
            )
        }

        return .forward(
            cliURL: cliURL,
            arguments: [cliURL.path] + Array(arguments.dropFirst())
        )
    }

    private static func shouldForward(arguments: [String]) -> Bool {
        let explicitArguments = arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
        guard let first = explicitArguments.first else {
            return false
        }
        if first == "-v" || first == "-h" {
            return true
        }
        if first.hasPrefix("--") {
            return true
        }
        if first.hasPrefix("-") {
            return false
        }
        return true
    }

    private static func exec(cliURL: URL, arguments: [String]) -> Never {
        var cArguments = arguments.map { strdup($0) }
        cArguments.append(nil)
        defer {
            for argument in cArguments {
                free(argument)
            }
        }

        _ = cArguments.withUnsafeMutableBufferPointer { buffer in
            cliURL.path.withCString { path in
                execv(path, buffer.baseAddress)
            }
        }

        let code = errno
        let reason = String(cString: strerror(code))
        let message = String(
            format: String(localized: "cli.forward.error.execFailed", defaultValue: "Failed to run bundled cmux CLI at %@: %@."),
            cliURL.path,
            reason
        )
        writeError(message)
        Darwin.exit(code == ENOENT ? 127 : 126)
    }

    private static func writeError(_ message: String) {
        let prefix = String(localized: "cli.error.prefix", defaultValue: "error:")
        fputs("\(prefix) \(message)\n", stderr)
        fflush(stderr)
    }
}
