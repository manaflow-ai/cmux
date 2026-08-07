import CmuxSudoBroker
import Darwin
import Foundation

extension CMUXCLI {
    func runSudoCommand(commandArgs: [String]) throws -> Int32 {
        let context = try sudoCLIContext()
        let parent = getppid()
        let command = SudoCLICommand(
            paths: context.paths,
            appBundleURL: context.appBundleURL,
            currentDirectoryURL: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            ),
            requesterProcessIdentifier: parent,
            requesterCommand: sudoRequesterCommand(processIdentifier: parent)
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
                    defaultValue: "sudo: the hidden runner could not resolve its enclosing cmux app"
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
                    defaultValue: "sudo requires the bundled cmux CLI from an installed or tagged cmux app"
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

    private func sudoRequesterCommand(processIdentifier: Int32) -> String {
        guard processIdentifier > 1 else { return sudoUnknownRequester }
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(processIdentifier, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else { return sudoUnknownRequester }
        let path = String(
            decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var sudoUnknownRequester: String {
        String(localized: "sudo.cli.requester.unknown", defaultValue: "unknown")
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
