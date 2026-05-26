import Darwin
import Foundation

enum CLIForwardingLaunchRouter {
    private static let guardKey = "CMUX_CLI_FORWARDED"

    /// If `argv` looks like a CLI invocation, exec the bundled CLI at
    /// `Contents/Resources/bin/cmux` and never return. macOS-launch arguments
    /// (`-psn_...`, other `-` flags) and `cmux://` URLs are left to the GUI.
    static func forwardToBundledCLIIfNeeded(
        arguments argv: [String] = CommandLine.arguments,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) {
        if getenv(guardKey) != nil { return }
        guard shouldForwardToBundledCLI(arguments: argv) else { return }

        guard let cliURL = bundledCLIURL(bundle: bundle, fileManager: fileManager) else {
            return
        }

        guard var cArgs = makeCStringArguments(cliPath: cliURL.path, arguments: argv) else {
            fputs("error: failed to allocate launch arguments for bundled cmux CLI\n", stderr)
            fflush(stderr)
            Darwin.exit(ENOMEM)
        }

        setenv(guardKey, "1", 1)

        _ = cliURL.path.withCString { execPath in
            cArgs.withUnsafeMutableBufferPointer { buffer in
                Darwin.execv(execPath, buffer.baseAddress)
            }
        }

        let execErrno = errno
        freeCStringArguments(cArgs)
        unsetenv(guardKey)

        let errorText = String(cString: strerror(execErrno))
        #if DEBUG
        NSLog("cmux: failed to exec bundled CLI at %@: %@", cliURL.path, errorText)
        #endif
        fputs("error: failed to launch bundled cmux CLI: \(errorText)\n", stderr)
        fflush(stderr)
        Darwin.exit(127)
    }

    static func shouldForwardToBundledCLI(arguments argv: [String]) -> Bool {
        guard argv.count > 1 else { return false }

        let first = argv[1]
        if first.isEmpty || first.hasPrefix("-") { return false }
        if first.contains("://") { return false }

        let guiLaunchSentinels: Set<String> = ["DEV", "STAGING", "NIGHTLY"]
        if guiLaunchSentinels.contains(first) { return false }

        return true
    }

    static func bundledCLIURL(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        executableURL: URL? = processExecutableURL()
    ) -> URL? {
        let bundleCandidate = bundle.resourceURL?.appendingPathComponent("bin/cmux")
        if let bundleCandidate, fileManager.isExecutableFile(atPath: bundleCandidate.path) {
            return bundleCandidate
        }

        guard let executableURL else { return nil }
        let resourcesURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let executableCandidate = resourcesURL.appendingPathComponent("bin/cmux")
        if fileManager.isExecutableFile(atPath: executableCandidate.path) {
            return executableCandidate
        }

        return nil
    }

    private static func makeCStringArguments(cliPath: String, arguments argv: [String]) -> [UnsafeMutablePointer<CChar>?]? {
        var cArgs: [UnsafeMutablePointer<CChar>?] = []

        guard let cliPathArgument = strdup(cliPath) else { return nil }
        cArgs.append(cliPathArgument)

        for arg in argv.dropFirst() {
            guard let duplicated = strdup(arg) else {
                freeCStringArguments(cArgs)
                return nil
            }
            cArgs.append(duplicated)
        }
        cArgs.append(nil)
        return cArgs
    }

    private static func freeCStringArguments(_ cArgs: [UnsafeMutablePointer<CChar>?]) {
        for ptr in cArgs where ptr != nil { free(ptr) }
    }

    private static func processExecutableURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    }
}
