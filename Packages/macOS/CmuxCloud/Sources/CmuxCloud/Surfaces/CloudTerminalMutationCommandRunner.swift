import CmuxCloudTui
import Foundation

/// Fences each terminal mutation transport call to its admitted provider lifecycle.
@MainActor
public struct CloudTerminalMutationCommandRunner: CloudTuiCommandRunning {
    public init(
        base: any CloudTuiCommandRunning,
        validate: @MainActor @Sendable () throws -> Void
    ) {
        self.base = base
        self.validate = validate
    }

    public let base: any CloudTuiCommandRunning
    public let validate: @MainActor @Sendable () throws -> Void

    public func runTuiCommand(arguments: CloudTuiRequest, deadline: Duration) async throws -> Data {
        try validate()
        do {
            let data: Data
            if arguments.idempotencyKey != nil {
                // An admitted mutation may finish after its pane closes. Its RPC owns
                // the existing bounded response lifetime; cancelling this waiter must
                // not retire that response or send an unsupported mutation cancellation.
                let request = Task { @MainActor in
                    try validate()
                    return try await base.runTuiCommand(arguments: arguments, deadline: deadline)
                }
                data = try await request.value
            } else {
                data = try await base.runTuiCommand(arguments: arguments, deadline: deadline)
            }
            try validate()
            return data
        } catch {
            // Transport failure is not proof that a mutation did not commit. A retired
            // caller still cannot continue or publish its result, including on error.
            try validate()
            throw error
        }
    }
}
