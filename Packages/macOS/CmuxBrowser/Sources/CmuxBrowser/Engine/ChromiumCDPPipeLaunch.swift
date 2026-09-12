import Darwin
import Foundation

/// Maps Foundation process pipes onto Chromium's required CDP descriptors.
struct ChromiumCDPPipeLaunch {
    private static let shellURL = URL(fileURLWithPath: "/bin/sh")
    private static let shellScript = "exec 3<&0 4>&1; exec 0</dev/null 1>/dev/null; exec \"$@\""

    let childStandardInput: Pipe
    let childStandardOutput: Pipe
    let transport: ChromiumCDPPipeTransport

    init() throws {
        let input = Pipe()
        let output = Pipe()
        do {
            try Self.markCloseOnExec(input.fileHandleForReading.fileDescriptor)
            try Self.markCloseOnExec(input.fileHandleForWriting.fileDescriptor)
            try Self.markCloseOnExec(output.fileHandleForReading.fileDescriptor)
            try Self.markCloseOnExec(output.fileHandleForWriting.fileDescriptor)
        } catch {
            try? input.fileHandleForReading.close()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            throw error
        }
        let commandDescriptor = Darwin.fcntl(
            input.fileHandleForWriting.fileDescriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        guard commandDescriptor >= 0 else {
            throw CDPError.disconnected(Self.posixErrorDescription(errno))
        }
        let responseDescriptor = Darwin.fcntl(
            output.fileHandleForReading.fileDescriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        guard responseDescriptor >= 0 else {
            let code = errno
            Darwin.close(commandDescriptor)
            throw CDPError.disconnected(Self.posixErrorDescription(code))
        }

        do {
            transport = try ChromiumCDPPipeTransport(
                commandDescriptor: commandDescriptor,
                responseDescriptor: responseDescriptor
            )
        } catch {
            throw error
        }
        childStandardInput = input
        childStandardOutput = output
    }

    func configure(
        _ process: Process,
        chromiumExecutable: URL,
        chromiumArguments: [String]
    ) {
        process.executableURL = Self.shellURL
        // The script is fixed and expands positional arguments without
        // interpolation. `exec` replaces the shell, so Process tracks the
        // actual Chromium PID for crash isolation and lifecycle signals.
        process.arguments = [
            "-c",
            Self.shellScript,
            "cmux-chromium",
            chromiumExecutable.standardizedFileURL.path,
        ] + chromiumArguments
        process.standardInput = childStandardInput
        process.standardOutput = childStandardOutput
    }

    /// Closes the parent's Foundation handles after their child duplicates exist.
    func closeFoundationHandles() {
        try? childStandardInput.fileHandleForReading.close()
        try? childStandardInput.fileHandleForWriting.close()
        try? childStandardOutput.fileHandleForReading.close()
        try? childStandardOutput.fileHandleForWriting.close()
    }

    private static func posixErrorDescription(_ code: Int32) -> String {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
    }

    private static func markCloseOnExec(_ descriptor: Int32) throws {
        let flags = Darwin.fcntl(descriptor, F_GETFD)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw CDPError.disconnected(posixErrorDescription(errno))
        }
    }
}
