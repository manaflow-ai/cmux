import Darwin
import Foundation

/// Runs the bundled PAM setup script through the user's interactive sudo terminal.
struct SystemSudoTouchIDSetupLauncher: SudoTouchIDSetupLaunching {
    func run(helperURL: URL) throws -> Int32 {
        let executable = "/usr/bin/sudo"
        let arguments = [executable, "/bin/bash", helperURL.standardizedFileURL.path]
        let environment = SudoProcessEnvironment().entries
        var processIdentifier: Int32 = 0
        let status = try withCStringArray(arguments) { arguments in
            try withCStringArray(environment) { environment in
                executable.withCString { executable in
                    posix_spawn(
                        &processIdentifier,
                        executable,
                        nil,
                        nil,
                        arguments,
                        environment
                    )
                }
            }
        }
        guard status == 0, processIdentifier > 1 else {
            throw Failure.spawn(status == 0 ? ECHILD : status)
        }

        // The synchronous CLI owns this direct child; waitpid is isolated to that boundary.
        var waitStatus: Int32 = 0
        var result: Int32
        repeat {
            result = waitpid(processIdentifier, &waitStatus, 0)
        } while result < 0 && errno == EINTR
        guard result == processIdentifier else { throw Failure.wait(errno) }
        let signal = waitStatus & 0x7f
        return signal == 0
            ? (waitStatus >> 8) & 0xff
            : min(255, 128 + signal)
    }

    private func withCStringArray<Value>(
        _ strings: [String],
        operation: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Value
    ) throws -> Value {
        var pointers = strings.map { strdup($0) }
        guard pointers.allSatisfy({ $0 != nil }) else {
            pointers.forEach { free($0) }
            throw Failure.allocation
        }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { throw Failure.allocation }
            return try operation(baseAddress)
        }
    }

    private enum Failure: Error {
        case allocation
        case spawn(Int32)
        case wait(Int32)
    }
}
