import Foundation

struct CmuxRunExecutionPlan: Equatable {
    let command: String
    let workingDirectory: String
    let workingDirectoryIdentity: CmuxRunWorkingDirectoryIdentity
    let target: CmuxRunExecutionTarget
    let placementDescription: String
    let targetDescription: String

    var launchCommand: String {
        CmuxRunShellCommandBuilder(
            command: command,
            workingDirectory: workingDirectory,
            approvedIdentity: workingDirectoryIdentity
        ).launchCommand
    }
}
