import Foundation

/// Creates cloud workspaces from a fresh fleet response and returns their exact local identity.
@MainActor
public final class CloudWorkspaceCoordinator {
    /// The selection shared with every Machines panel.
    public let defaultMachineStore: DefaultCloudMachineStore
    private let allowsOperation: @MainActor () -> Bool
    private let loadMachines: @MainActor () async throws -> [CloudMachineDescriptor]
    private let createWorkspace: @MainActor (String, Bool) async throws -> UUID?

    /// Whether Cloud Machines and the current authenticated account permit an action.
    public var isAvailable: Bool { allowsOperation() }

    /// Assembles the operation from app-owned authentication and cloud services.
    /// - Parameters:
    ///   - defaultMachineStore: The app's shared selection model.
    ///   - allowsOperation: Reads live feature and account availability.
    ///   - loadMachines: Loads the complete, authoritative fleet, throwing on failure.
    ///   - createWorkspace: Creates and opens a workspace on the selected machine.
    public init(
        defaultMachineStore: DefaultCloudMachineStore,
        allowsOperation: @escaping @MainActor () -> Bool,
        loadMachines: @escaping @MainActor () async throws -> [CloudMachineDescriptor],
        createWorkspace: @escaping @MainActor (String, Bool) async throws -> UUID?
    ) {
        self.defaultMachineStore = defaultMachineStore
        self.allowsOperation = allowsOperation
        self.loadMachines = loadMachines
        self.createWorkspace = createWorkspace
    }

    /// Creates one workspace using a caller-owned task.
    /// - Parameter focus: Whether to focus the new local workspace.
    /// - Returns: The exact created local workspace ID, or nil when unavailable or empty.
    /// - Throws: Cancellation or a cloud service failure.
    public func createOnDefaultMachine(focus: Bool) async throws -> UUID? {
        guard isAvailable else { return nil }
        try Task.checkCancellation()
        let machines = try await loadMachines()
        try Task.checkCancellation()
        guard isAvailable,
              let id = defaultMachineStore.resolveMachineID(from: machines, isComplete: true) else { return nil }
        return try await createWorkspace(id, focus)
    }
}
