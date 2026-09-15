import Foundation

/// Failure raised when a captured Cloud machine is no longer in the
/// authoritative fleet response. Keeping this distinct from an empty/default
/// selection prevents callers from silently routing the request to this Mac.
public enum CloudWorkspaceCoordinatorError: Error, Equatable, Sendable {
    case machineUnavailable(String)
    case targetWindowUnavailable(UUID)
}

/// Creates cloud workspaces from a fresh fleet response and returns their exact local identity.
@MainActor
public final class CloudWorkspaceCoordinator {
    /// The selection shared with every Machines panel.
    public let defaultMachineStore: DefaultCloudMachineStore
    private let allowsOperation: @MainActor () -> Bool
    private let loadMachines: @MainActor () async throws -> [CloudMachineDescriptor]
    private let createWorkspace: @MainActor (String, Bool) async throws -> UUID?
    private let createWorkspaceWithContext: (@MainActor (String, Bool, UUID) async throws -> UUID?)?

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
        createWorkspace: @escaping @MainActor (String, Bool) async throws -> UUID?,
        createWorkspaceWithContext: (@MainActor (String, Bool, UUID) async throws -> UUID?)? = nil
    ) {
        self.defaultMachineStore = defaultMachineStore
        self.allowsOperation = allowsOperation
        self.loadMachines = loadMachines
        self.createWorkspace = createWorkspace
        self.createWorkspaceWithContext = createWorkspaceWithContext
    }

    /// Creates a workspace on the specified cloud machine.
    /// - Parameters:
    ///   - id: The cloud machine identifier.
    ///   - focus: Whether to focus the new local workspace.
    /// - Returns: The exact created local workspace ID, or nil when unavailable.
    /// - Throws: Cancellation or a cloud service failure.
    public func createOnMachine(id: String, focus: Bool) async throws -> UUID? {
        guard isAvailable, !id.isEmpty else { return nil }
        try Task.checkCancellation()
        return try await createWorkspace(id, focus)
    }

    /// Creates a workspace on the persisted default cloud machine.
    /// - Parameter focus: Whether to focus the new local workspace.
    /// - Returns: The exact created local workspace ID, or nil when unavailable.
    /// - Throws: Cancellation or a cloud service failure.
    public func createOnDefaultMachine(focus: Bool) async throws -> UUID? {
        guard isAvailable else { return nil }
        try Task.checkCancellation()
        let machines = try await loadMachines()
        try Task.checkCancellation()
        guard isAvailable,
              let id = defaultMachineStore.resolveMachineID(from: machines, isComplete: true) else { return nil }
        return try await createOnMachine(id: id, focus: focus)
    }

    /// Creates a workspace on the exact machine captured by the caller.
    ///
    /// The fleet response is still checked so a deleted or unavailable machine
    /// fails closed. The selected id is never replaced with the persisted
    /// default while the asynchronous create is in flight.
    /// - Parameters:
    ///   - machineID: Immutable Cloud machine identity captured at invocation.
    ///   - focus: Whether to focus the newly opened local projection.
    /// - Returns: The exact created local workspace ID, or nil when unavailable.
    /// - Throws: Cancellation, machine unavailability, or a Cloud service failure.
    public func createOnMachine(machineID: String, focus: Bool, windowID: UUID? = nil) async throws -> UUID? {
        guard isAvailable else { return nil }
        let capturedMachineID = machineID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !capturedMachineID.isEmpty else {
            throw CloudWorkspaceCoordinatorError.machineUnavailable(machineID)
        }
        try Task.checkCancellation()
        let machines = try await loadMachines()
        try Task.checkCancellation()
        guard isAvailable,
              machines.contains(where: { $0.id == capturedMachineID }) else {
            throw CloudWorkspaceCoordinatorError.machineUnavailable(capturedMachineID)
        }
        if let windowID, let createWorkspaceWithContext {
            return try await createWorkspaceWithContext(capturedMachineID, focus, windowID)
        }
        return try await createWorkspace(capturedMachineID, focus)
    }
}
