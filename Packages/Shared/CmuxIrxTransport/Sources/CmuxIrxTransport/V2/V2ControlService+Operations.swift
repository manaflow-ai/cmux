import Foundation

extension V2ControlService {
    /// Refreshes one API ticket in place; concurrent callers share the same operation.
    /// - Parameter forceAuthRefresh: Requests a new Stack token after an authentication rejection.
    /// - Returns: The replacement one-hour API credential.
    /// - Throws: A typed server, cooldown, or transport error, preserving the previous credential.
    public func refreshAPITicket(forceAuthRefresh: Bool = false) async throws -> V2Ticket {
        if let task = ticketTask { return try await task.value }
        guard let run = runID else { throw V2ControlFailure.stopped }
        let task = Task { try await self.issueTicket(forceRefresh: forceAuthRefresh, run: run) }
        let taskID = UUID()
        ticketTaskID = taskID
        ticketTask = task
        defer { if ticketTaskID == taskID { ticketTask = nil; ticketTaskID = nil } }
        return try await task.value
    }

    private func issueTicket(forceRefresh: Bool, run: UUID) async throws -> V2Ticket {
        let token = try await stackToken(forceRefresh: forceRefresh, run: run)
        try assertCurrent(run)
        let request = V2TicketRequest(requestID: UUID().uuidString.lowercased(), schemaID: .ticketRequestV1, stackAccessToken: token)
        let response = try await perform(request, requestID: request.requestID, schemaID: request.schemaID.rawValue, response: V2TicketResponse.self, run: run, canRefreshAuth: false)
        try assertCurrent(run)
        cache.ticket = response.ticket
        failure = nil
        try await persist(run: run)
        return response.ticket
    }

    func stackToken(forceRefresh: Bool, run: UUID) async throws -> String {
        if let authTask { return try await authTask.value }
        let task = Task { try await dependencies.stackAccessToken(forceRefresh) }
        let taskID = UUID()
        authTaskID = taskID
        authTask = task
        defer { if authTaskID == taskID { authTask = nil; authTaskID = nil } }
        let result = try await task.value
        try assertCurrent(run)
        return result
    }

    /// Mints replacement relay credentials without cancelling any current endpoint or peer.
    /// - Returns: One new 30-minute credential per relay URL.
    /// - Throws: A typed failure; existing valid credentials remain in the snapshot.
    public func refreshRelayCredentials() async throws -> [V2RelayCredential] {
        if let relayTask { return try await relayTask.value }
        guard let run = runID else { throw V2ControlFailure.stopped }
        let task = Task { try await self.issueRelayCredentials(run: run) }
        let taskID = UUID()
        relayTaskID = taskID
        relayTask = task
        defer { if relayTaskID == taskID { relayTask = nil; relayTaskID = nil } }
        return try await task.value
    }

    private func issueRelayCredentials(run: UUID) async throws -> [V2RelayCredential] {
        let request = V2RelayRequest(requestID: UUID().uuidString.lowercased(), schemaID: .relayRequestV1)
        let response = try await perform(request, requestID: request.requestID, schemaID: request.schemaID.rawValue, response: V2RelayResponse.self, run: run)
        try assertCurrent(run)
        cache.relayCredentials = response.credentials
        failure = nil
        try await persist(run: run)
        return response.credentials
    }

    /// Fetches the complete permitted directory through one coalesced paginated operation.
    /// - Returns: One consistent team revision containing only authorized devices.
    /// - Throws: A typed failure without presenting a partially received list as complete.
    public func refreshDirectory() async throws -> V2Directory {
        if let directoryTask { return try await directoryTask.value }
        guard let run = runID else { throw V2ControlFailure.stopped }
        let task = Task { try await self.loadDirectory(run: run) }
        let taskID = UUID()
        directoryTaskID = taskID
        directoryTask = task
        defer { if directoryTaskID == taskID { directoryTask = nil; directoryTaskID = nil } }
        return try await task.value
    }

    private func loadDirectory(run: UUID) async throws -> V2Directory {
        // A concurrent committed change restarts pagination instead of mixing revisions.
        for _ in 0..<3 {
            var first: V2Directory?
            var cursor: String?
            var seenCursors = Set<String>()
            var devices: [V2DeviceRecord] = []
            var inconsistent = false
            repeat {
                let request = V2DirectoryRequest(cursor: cursor, haveRevision: nil, requestID: UUID().uuidString.lowercased(), schemaID: .directoryRequestV1)
                let response = try await perform(request, requestID: request.requestID, schemaID: request.schemaID.rawValue, response: V2DirectoryResponse.self, run: run)
                try assertCurrent(run)
                let page = response.directory
                guard page.teamID == descriptor.identity.teamID else { throw V2ControlFailure.scopeMismatch }
                if let first, first.revision != page.revision { inconsistent = true; break }
                if first == nil { first = page }
                devices.append(contentsOf: page.devices)
                guard devices.count <= 4096 else { throw V2ControlFailure.capacityExceeded }
                cursor = page.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted { throw V2ControlFailure.invalidWireData }
            } while cursor != nil
            guard !inconsistent, let first, first.revision >= wantedDirectoryRevision else { continue }
            let directory = V2Directory(
                devices: devices, issuedAt: first.issuedAt, nextCursor: nil,
                permissionExpiresAt: first.permissionExpiresAt, relayURLs: first.relayURLs,
                revision: first.revision, teamID: first.teamID
            )
            cache.directory = directory
            failure = nil
            try await persist(run: run)
            return directory
        }
        throw V2ControlFailure.server(V2ErrorResponse(code: .revisionConflict, requestID: "directory-refresh", retryable: true, retryAfterMS: 1000, schemaID: .errorV1))
    }

    /// Updates relay-only metadata without reenrolling or changing device generation.
    /// - Parameter metadata: Current device presentation, capabilities, and relay URLs.
    /// - Throws: A typed operation error; an uncertain mutation is not replayed automatically.
    public func updateMetadata(_ metadata: V2DeviceMetadata) async throws {
        guard let run = runID else { throw V2ControlFailure.stopped }
        guard metadata.platform != .mac || metadata.pairingEnabled else { throw V2ControlFailure.scopeMismatch }
        guard metadata != descriptor.metadata else { return }
        let request = V2MetadataRequest(metadata: metadata, requestID: UUID().uuidString.lowercased(), schemaID: .deviceMetadataV1)
        _ = try await perform(request, requestID: request.requestID, schemaID: request.schemaID.rawValue, response: V2CompletedResponse.self, run: run)
        try assertCurrent(run)
        descriptor = V2DeviceDescriptor(endpointID: descriptor.endpointID, identity: descriptor.identity, identityGeneration: descriptor.identityGeneration, metadata: metadata)
    }

    /// Removes a device using the current session's explicit management permission.
    /// - Parameter deviceRecordID: The selected v2 device record.
    /// - Throws: A typed authorization, conflict, or transport error.
    public func revokeDevice(_ deviceRecordID: String) async throws {
        guard let run = runID else { throw V2ControlFailure.stopped }
        let request = V2RevokeRequest(deviceRecordID: deviceRecordID, requestID: UUID().uuidString.lowercased(), schemaID: .deviceRevokeV1)
        _ = try await perform(request, requestID: request.requestID, schemaID: request.schemaID.rawValue, response: V2CompletedResponse.self, run: run)
        try assertCurrent(run)
        requestDirectoryRefresh(run: run)
    }

    /// Changes an explicit user-to-device permission.
    /// - Parameter permission: The exact connect/manage grant being changed.
    /// - Throws: A typed authorization, conflict, or transport error.
    public func updatePermission(_ permission: V2Permission) async throws {
        guard let run = runID else { throw V2ControlFailure.stopped }
        let request = V2PermissionRequest(permission: permission, requestID: UUID().uuidString.lowercased(), schemaID: .permissionUpdateV1)
        _ = try await perform(request, requestID: request.requestID, schemaID: request.schemaID.rawValue, response: V2CompletedResponse.self, run: run)
        try assertCurrent(run)
        requestDirectoryRefresh(run: run)
    }

    /// Updates team relay preferences against a known revision.
    /// - Parameters:
    ///   - relayURLs: HTTPS relay locations, never direct IP or port coordinates.
    ///   - expectedRevision: The last revision the caller observed.
    /// - Throws: A typed conflict or authorization error requiring caller reconciliation.
    public func updateRelayPreferences(relayURLs: [String], expectedRevision: Int) async throws {
        guard let run = runID else { throw V2ControlFailure.stopped }
        let request = V2PreferencesRequest(expectedRevision: expectedRevision, relayURLs: relayURLs, requestID: UUID().uuidString.lowercased(), schemaID: .preferencesUpdateV1)
        _ = try await perform(request, requestID: request.requestID, schemaID: request.schemaID.rawValue, response: V2CompletedResponse.self, run: run)
        try assertCurrent(run)
        requestDirectoryRefresh(run: run)
    }
}
