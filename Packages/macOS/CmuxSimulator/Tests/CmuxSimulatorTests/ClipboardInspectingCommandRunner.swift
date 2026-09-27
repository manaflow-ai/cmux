import CmuxFoundation
import Foundation
@testable import CmuxSimulator

actor ClipboardInspectingCommandRunner: CommandRunning {
    private(set) var observation: ClipboardCommandObservation?

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        guard executable == "/bin/sh", let path = arguments.last else {
            return clipboardSuccessfulCommandResult()
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        observation = ClipboardCommandObservation(
            path: path,
            text: text,
            permissions: permissions
        )
        return clipboardSuccessfulCommandResult()
    }
}

private func clipboardSuccessfulCommandResult() -> CommandResult {
    CommandResult(
        stdout: "",
        stderr: "",
        exitStatus: 0,
        timedOut: false,
        executionError: nil
    )
}
