import Foundation

struct CmuxRunExecutionPlan: Equatable {
    let command: String
    let workingDirectory: String
    let target: CmuxRunExecutionTarget
    let placementDescription: String
    let targetDescription: String

    var launchCommand: String {
        CmuxRunShellCommandBuilder.launchCommand(
            for: command,
            workingDirectory: workingDirectory
        )
    }
}
