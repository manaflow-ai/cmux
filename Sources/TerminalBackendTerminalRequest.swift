import Foundation

/// Idempotent identity and spawn inputs for one daemon-owned terminal.
struct TerminalBackendTerminalRequest: Equatable, Sendable {
    let appWorkspaceID: UUID
    let appSurfaceID: UUID
    let workingDirectory: String?
    let command: String?
    let arguments: [String]?
    let environment: [String: String]
    let initialInput: String?
    let waitAfterCommand: Bool
    let columns: UInt16
    let rows: UInt16

    init(
        appWorkspaceID: UUID,
        appSurfaceID: UUID,
        workingDirectory: String?,
        command: String?,
        arguments: [String]?,
        environment: [String: String],
        initialInput: String?,
        waitAfterCommand: Bool,
        columns: UInt16,
        rows: UInt16
    ) {
        precondition(command == nil || arguments == nil)
        precondition(command?.isEmpty != true)
        precondition(arguments?.isEmpty != true)
        self.appWorkspaceID = appWorkspaceID
        self.appSurfaceID = appSurfaceID
        self.workingDirectory = workingDirectory
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.initialInput = initialInput
        self.waitAfterCommand = waitAfterCommand
        self.columns = columns
        self.rows = rows
    }

    /// Retargets only canonical placement identity. Spawn fields remain creation-only
    /// and are ignored by the daemon when this stable surface already exists.
    func reparented(to workspaceID: UUID) -> Self {
        Self(
            appWorkspaceID: workspaceID,
            appSurfaceID: appSurfaceID,
            workingDirectory: workingDirectory,
            command: command,
            arguments: arguments,
            environment: environment,
            initialInput: initialInput,
            waitAfterCommand: waitAfterCommand,
            columns: columns,
            rows: rows
        )
    }
}
