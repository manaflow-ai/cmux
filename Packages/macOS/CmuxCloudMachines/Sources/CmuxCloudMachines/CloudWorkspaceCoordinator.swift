import Foundation

/// Creates cloud workspaces from a fresh fleet response and returns their exact local identity.
@MainActor
public final class CloudWorkspaceCoordinator {
    private let allowsOperation: @MainActor () -> Bool
    private let loadMachines: @MainActor () async throws -> [CloudMachineDescriptor]
    private let createWorkspace: @MainActor (String, Bool) async throws -> UUID?
    private let createWorkspaceWithContext: (@MainActor (String, Bool, UUID) async throws -> UUID?)?
    private var creatingMachineIDs = Set<String>()

    /// Whether Cloud Machines and the current authenticated account permit an action.
    public var isAvailable: Bool { allowsOperation() }

    /// Assembles the operation from app-owned authentication and cloud services.
    /// - Parameters:
    ///   - allowsOperation: Reads live feature and account availability.
    ///   - loadMachines: Loads the complete, authoritative fleet, throwing on failure.
    ///   - createWorkspace: Creates and opens a workspace on an explicit machine.
    ///   - createWorkspaceWithContext: Optionally projects into a caller-owned window.
    public init(
        allowsOperation: @escaping @MainActor () -> Bool,
        loadMachines: @escaping @MainActor () async throws -> [CloudMachineDescriptor],
        createWorkspace: @escaping @MainActor (String, Bool) async throws -> UUID?,
        createWorkspaceWithContext: (@MainActor (String, Bool, UUID) async throws -> UUID?)? = nil
    ) {
        self.allowsOperation = allowsOperation
        self.loadMachines = loadMachines
        self.createWorkspace = createWorkspace
        self.createWorkspaceWithContext = createWorkspaceWithContext
    }

    /// Creates one workspace on the exact machine captured by the caller.
    /// - Parameters:
    ///   - machineID: Immutable Cloud machine identity captured at invocation.
    ///   - focus: Whether to focus the new local workspace.
    ///   - windowID: Optional originating window identity.
    /// - Returns: The exact created local workspace ID, or nil when unavailable.
    /// - Throws: Cancellation, machine unavailability, or a Cloud service failure.
    public func createOnMachine(machineID: String, focus: Bool, windowID: UUID? = nil) async throws -> UUID? {
        guard isAvailable else { return nil }
        let capturedMachineID = machineID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !capturedMachineID.isEmpty else { throw CloudWorkspaceCoordinatorError.machineUnavailable(machineID) }
        try Task.checkCancellation()
        let machines = try await loadMachines()
        try Task.checkCancellation()
        guard isAvailable else { return nil }
        guard machines.contains(where: { $0.id == capturedMachineID }) else {
            throw CloudWorkspaceCoordinatorError.machineUnavailable(capturedMachineID)
        }
        guard creatingMachineIDs.insert(capturedMachineID).inserted else { return nil }
        defer { creatingMachineIDs.remove(capturedMachineID) }
        if let windowID, let createWorkspaceWithContext {
            return try await createWorkspaceWithContext(capturedMachineID, focus, windowID)
        }
        return try await createWorkspace(capturedMachineID, focus)
    }
}
