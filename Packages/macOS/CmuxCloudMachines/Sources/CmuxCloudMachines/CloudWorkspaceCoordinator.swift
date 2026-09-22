import Foundation

/// Creates Cloud workspaces through the sidebar's ordering and account authority.
@MainActor
public final class CloudWorkspaceCoordinator {
    private let machinePinStore: CloudMachinePinStore
    private let allowsOperation: @MainActor () -> Bool
    private let loadMachines: @MainActor () async throws -> [String]
    private let createWorkspace: @MainActor (CloudWorkspaceCreationRequest) async throws -> UUID?
    private let targetResolver = CloudWorkspaceTargetResolver()

    /// Whether the feature and current authenticated account permit an action.
    public var isAvailable: Bool { allowsOperation() }
    /// The same account/team scope that owns sidebar pins and ordering.
    public var scopeIdentifier: String? { machinePinStore.scopeIdentifier }

    /// Composes live authentication, the sidebar's order store, and Cloud operations.
    /// - Parameters:
    ///   - machinePinStore: The one store shared with every Machines panel.
    ///   - allowsOperation: Reads live feature and account availability.
    ///   - loadMachines: Loads the complete authenticated fleet in its reported order.
    ///   - createWorkspace: Creates on the exact machine and projects into the captured window.
    public init(
        machinePinStore: CloudMachinePinStore,
        allowsOperation: @escaping @MainActor () -> Bool,
        loadMachines: @escaping @MainActor () async throws -> [String],
        createWorkspace: @escaping @MainActor (CloudWorkspaceCreationRequest) async throws -> UUID?
    ) {
        self.machinePinStore = machinePinStore
        self.allowsOperation = allowsOperation
        self.loadMachines = loadMachines
        self.createWorkspace = createWorkspace
    }

    /// Creates window-owned memory bound to the sidebar's account/team source.
    /// - Returns: Fresh selection state; no persisted default-machine value is read.
    public func makeSelectionState() -> CloudWorkspaceSelectionState {
        CloudWorkspaceSelectionState(scopeProvider: { [machinePinStore] in machinePinStore.scopeIdentifier })
    }

    /// Creates on an explicitly selected machine, preserving Cmd+N's current-workspace behavior.
    /// - Parameters:
    ///   - request: The machine, window, and scope captured at dispatch.
    /// - Returns: The created local workspace identity, or nil if access is unavailable.
    /// - Throws: Cancellation or an operation failure.
    public func createOnMachine(_ request: CloudWorkspaceCreationRequest) async throws -> UUID? {
        guard isAvailable, !request.machineID.isEmpty, request.scopeID == scopeIdentifier else { return nil }
        try Task.checkCancellation()
        return try await createWorkspace(request)
    }

    /// Creates on the remembered Cloud machine or the first available machine in sidebar order.
    /// - Parameters:
    ///   - selection: Validated window-owned selection captured at action dispatch.
    ///   - windowID: The originating window.
    ///   - scopeID: The account/team captured synchronously at dispatch.
    /// - Returns: The exact created local workspace identity, or nil if access changed.
    /// - Throws: ``CloudWorkspaceCreationError/noMachines``, cancellation, or an operation failure.
    public func createOnResolvedMachine(
        selection: CloudWorkspaceSelection?, windowID: UUID, scopeID: String
    ) async throws -> UUID? {
        guard isAvailable, scopeID == scopeIdentifier else { return nil }
        try Task.checkCancellation()
        let machineIDs = try await loadMachines()
        try Task.checkCancellation()
        guard isAvailable, scopeID == scopeIdentifier else { return nil }
        machinePinStore.refreshScope()
        machinePinStore.remember(machineIDs: machineIDs)
        let orderedIDs = machinePinStore.orderedMachineIDs(machineIDs)
        guard let id = targetResolver.resolve(
            lastSelection: selection, currentScopeID: scopeID, sidebarMachineIDs: orderedIDs
        ) else { throw CloudWorkspaceCreationError.noMachines }
        return try await createWorkspace(CloudWorkspaceCreationRequest(machineID: id, scopeID: scopeID, windowID: windowID))
    }
}
