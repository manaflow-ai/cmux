/// Creation inputs for one stable daemon-owned terminal in a bounded batch.
public struct BackendEnsureTerminalRequest: Equatable, Sendable {
    public let workspaceID: WorkspaceID
    public let surfaceID: SurfaceID
    public let workingDirectory: String?
    public let command: String?
    public let arguments: [String]?
    public let environment: [String: String]
    public let initialInput: String?
    public let waitAfterCommand: Bool
    public let columns: UInt16
    public let rows: UInt16

    public init(
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        workingDirectory: String? = nil,
        command: String? = nil,
        arguments: [String]? = nil,
        environment: [String: String] = [:],
        initialInput: String? = nil,
        waitAfterCommand: Bool = false,
        columns: UInt16,
        rows: UInt16
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.workingDirectory = workingDirectory
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.initialInput = initialInput
        self.waitAfterCommand = waitAfterCommand
        self.columns = columns
        self.rows = rows
    }

    internal var jsonValue: BackendJSONValue {
        var value: [String: BackendJSONValue] = [
            "workspace_uuid": .string(workspaceID.description),
            "surface_uuid": .string(surfaceID.description),
            "cols": .unsignedInteger(UInt64(columns)),
            "rows": .unsignedInteger(UInt64(rows)),
        ]
        if let workingDirectory { value["cwd"] = .string(workingDirectory) }
        if let command { value["command"] = .string(command) }
        if let arguments {
            value["argv"] = .array(arguments.map(BackendJSONValue.string))
        }
        if !environment.isEmpty {
            value["env"] = .array(
                environment.keys.sorted().map { name in
                    .object([
                        "name": .string(name),
                        "value": .string(environment[name] ?? ""),
                    ])
                }
            )
        }
        if let initialInput { value["initial_input"] = .string(initialInput) }
        if waitAfterCommand { value["wait_after_command"] = .bool(true) }
        return .object(value)
    }
}
