import Foundation

/// Fences each terminal mutation transport call to its admitted provider lifecycle.
@MainActor
struct CloudTerminalMutationCommandRunner: CloudTuiCommandRunning {
    let base: any CloudTuiCommandRunning
    let validate: @MainActor @Sendable () throws -> Void

    func runTuiCommand(arguments: CloudTuiRequest, deadline: Duration) async throws -> Data {
        try validate()
        let data = try await base.runTuiCommand(arguments: arguments, deadline: deadline)
        try validate()
        return data
    }
}
