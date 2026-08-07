import CmuxSudoBroker
import Darwin
import Foundation

extension CMUXCLI {
    func runSudoCommand(commandArgs: [String]) throws -> Int32 {
        let context = try sudoCLIContext()
        let parent = getppid()
        guard let requester = sudoRequester(processIdentifier: parent) else {
            throw CLIError(
                message: String(
                    localized: "sudo.cli.error.requester_identity",
                    defaultValue: "sudo: could not verify the requesting process; retry the command"
                )
            )
        }
        let command = SudoCLICommand(
            paths: context.paths,
            appBundleURL: context.appBundleURL,
            currentDirectoryURL: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            ),
            requesterIdentity: requester.identity,
            requesterCommand: requester.command
        )
        do {
            return try command.run(arguments: commandArgs)
        } catch let error as SudoCLICommandError {
            writeSudoError(error.message)
            return error.exitCode
        }
    }

    func runHiddenSudoRunner(commandArgs: [String]) -> Int32 {
        guard commandArgs.count == 1 else { return 2 }
        do {
            let context = try sudoCLIContext()
            let runner = SudoExecutionRunner(
                paths: context.paths,
                expectedParentExecutableURL: context.appExecutableURL,
                messages: .localized
            )
            return runner.run(requestID: commandArgs[0])
        } catch {
            writeSudoError(
                String(
                    localized: "sudo.cli.error.runner_context",
                    defaultValue: "sudo: could not start secure execution; retry from a cmux terminal"
                )
            )
            return 126
        }
    }

    private func sudoCLIContext() throws -> SudoCLIContext {
        guard let bundle = CLIExecutableLocator.enclosingAppBundle(),
              let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty,
              let appExecutableURL = bundle.executableURL,
              let applicationSupportDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
              ).first else {
            throw CLIError(
                message: String(
                    localized: "sudo.cli.error.enclosing_app",
                    defaultValue: "sudo: use the cmux CLI included with the cmux app, then retry"
                )
            )
        }
        return SudoCLIContext(
            paths: SudoBrokerPaths(
                applicationSupportDirectory: applicationSupportDirectory,
                bundleIdentifier: bundleIdentifier
            ),
            appBundleURL: bundle.bundleURL,
            appExecutableURL: appExecutableURL
        )
    }

    private func sudoRequester(
        processIdentifier: Int32
    ) -> (identity: SudoProcessIdentity, command: String)? {
        guard processIdentifier > 1,
              getppid() == processIdentifier,
              let identityBefore = sudoRequesterIdentity(
                  processIdentifier: processIdentifier
              ) else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(processIdentifier, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0,
              let path = String(
                  bytes: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
                  encoding: .utf8
              ),
              let identityAfter = sudoRequesterIdentity(
                  processIdentifier: processIdentifier
              ),
              identityBefore == identityAfter,
              getppid() == processIdentifier else {
            return nil
        }
        return (
            identity: identityBefore,
            command: URL(fileURLWithPath: path).lastPathComponent
        )
    }

    private func sudoRequesterIdentity(
        processIdentifier: Int32
    ) -> SudoProcessIdentity? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(expectedSize)
        )
        guard size == expectedSize, info.pbi_status != UInt32(SZOMB) else {
            return nil
        }
        return SudoProcessIdentity(
            processIdentifier: processIdentifier,
            startSeconds: Int64(info.pbi_start_tvsec),
            startMicroseconds: Int32(info.pbi_start_tvusec)
        )
    }

    private func writeSudoError(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
    }

    private struct SudoCLIContext {
        let paths: SudoBrokerPaths
        let appBundleURL: URL
        let appExecutableURL: URL
    }
}
