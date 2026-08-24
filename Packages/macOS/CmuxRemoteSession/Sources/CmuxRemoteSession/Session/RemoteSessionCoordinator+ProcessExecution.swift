internal import Foundation

// Blocking SSH/SCP/dev-build execution through the injected process runner.
// Calls stay on the coordinator's serial utility queue; file-backed stdin lets
// large helper binaries flow through SSH without buffering them in memory.
extension RemoteSessionCoordinator {
    func sshExec(
        arguments: [String],
        stdin: Data? = nil,
        timeout: TimeInterval = 15
    ) throws -> RemoteCommandResult {
        try runProcess(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            environment: configuration.sshProcessEnvironment,
            stdin: stdin,
            timeout: timeout
        )
    }

    func sshExec(
        arguments: [String],
        stdinFile: URL,
        timeout: TimeInterval = 15
    ) throws -> RemoteCommandResult {
        // A host or caller can configure StdinNull=yes; OpenSSH would then
        // discard this file while `cat` still exits successfully. Its first
        // option value wins, so pin file-backed execs before caller options.
        let fileInputArguments = ["-o", "StdinNull=no"] + arguments
        return try processRunner.run(
            RemoteProcessRequest(
                executable: "/usr/bin/ssh",
                arguments: fileInputArguments,
                environment: configuration.sshProcessEnvironment,
                stdinFile: stdinFile,
                timeout: timeout
            ),
            operation: nil
        )
    }

    func scpExec(
        arguments: [String],
        timeout: TimeInterval = 30,
        operation: (any RemoteTransferCancelling)? = nil
    ) throws -> RemoteCommandResult {
        try runProcess(
            executable: "/usr/bin/scp",
            arguments: arguments,
            environment: configuration.sshProcessEnvironment,
            stdin: nil,
            timeout: timeout,
            operation: operation
        )
    }

    func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdin: Data?,
        timeout: TimeInterval,
        operation: (any RemoteTransferCancelling)? = nil
    ) throws -> RemoteCommandResult {
        try processRunner.run(
            RemoteProcessRequest(
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory,
                stdin: stdin,
                timeout: timeout
            ),
            operation: operation
        )
    }
}
