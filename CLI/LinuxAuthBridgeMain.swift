#if os(Linux)
import CMUXAuthCore
import Foundation
import Glibc

@main
struct LinuxCMUXMain {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "auth-bridge" {
                try runAuthBridge()
                return
            }
            try runFallbackCLI(arguments: arguments)
        } catch let error as ExitError {
            writeError(error.message)
            exit(error.code)
        } catch {
            writeError("transport_error")
            exit(1)
        }
    }

    private static func runAuthBridge() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard !input.isEmpty else {
            throw ExitError("invalid_params:auth-bridge requires stdin JSON")
        }
        do {
            let output = try CMUXAuthBridge().handleJSONRequest(input)
            FileHandle.standardOutput.write(output)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch let error as CMUXAuthBridgeError {
            throw ExitError(authBridgeMessage(for: error))
        } catch is DecodingError {
            throw ExitError("invalid_params:invalid_json")
        }
    }

    private static func runFallbackCLI(arguments: [String]) throws -> Never {
        guard let executable = fallbackCLIPath() else {
            throw ExitError("backend_unavailable:cmux-linux fallback not found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        exit(process.terminationStatus)
    }

    private static func fallbackCLIPath() -> String? {
        if let explicit = ProcessInfo.processInfo.environment["CMUX_LINUX_FALLBACK_CLI"],
           isExecutable(explicit) {
            return explicit
        }
        guard let executablePath = currentExecutablePath() else {
            return nil
        }
        let sibling = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .appendingPathComponent("cmux-linux")
            .path
        return isExecutable(sibling) ? sibling : nil
    }

    private static func currentExecutablePath() -> String? {
        if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") {
            return resolved
        }
        return CommandLine.arguments.first
    }

    private static func authBridgeMessage(for error: CMUXAuthBridgeError) -> String {
        switch error {
        case .backendUnavailable:
            return "backend_unavailable"
        case .invalidRequest(let reason):
            return "invalid_params:\(reason)"
        }
    }

    private static func isExecutable(_ path: String) -> Bool {
        access(path, X_OK) == 0
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private struct ExitError: Error {
    let message: String
    let code: Int32

    init(_ message: String, code: Int32 = 1) {
        self.message = message
        self.code = code
    }
}
#endif
