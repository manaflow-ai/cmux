import Foundation

/// A launcher result translated at the app boundary.
public struct CloudMachineCreateCompletion: Sendable {
    let succeeded: Bool
    let wasCancelled: Bool
    let output: String
    let failureOutput: String
    let machineID: String?
    let workspaceID: UUID?

    /// Captures the authoritative receipt and safe presentation of a process result.
    ///
    /// - Parameters:
    ///   - succeeded: Whether creation and opening both succeeded.
    ///   - wasCancelled: Whether the launcher terminated the process intentionally.
    ///   - output: Raw protocol transcript, used only for receipt parsing.
    ///   - failureOutput: Already redacted and localized error text for presentation.
    ///   - machineID: Authoritative machine receipt, if present.
    ///   - workspaceID: Local workspace receipt, if opening succeeded.
    public init(succeeded: Bool, wasCancelled: Bool, output: String, failureOutput: String, machineID: String?, workspaceID: UUID?) {
        self.succeeded = succeeded
        self.wasCancelled = wasCancelled
        self.output = output
        self.failureOutput = failureOutput
        self.machineID = machineID
        self.workspaceID = workspaceID
    }
}
