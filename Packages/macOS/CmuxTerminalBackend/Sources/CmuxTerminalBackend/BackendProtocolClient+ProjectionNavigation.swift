public import Foundation

public extension BackendProtocolClient {
    /// Claims or reclaims one daemon-retained v2 logical-window record.
    ///
    /// - Parameters:
    ///   - logicalPresentationID: The stable logical Swift-window identifier.
    ///   - authority: The exact daemon and persisted-session authority.
    ///   - expectedTopologyRevision: The exact canonical topology revision.
    /// - Returns: A typed applied response or structured conflict.
    /// - Throws: A transport, decoding, or malformed-protocol error.
    func claimProjectionNavigationV2(
        logicalPresentationID: UUID,
        authority: BackendAuthority,
        expectedTopologyRevision: UInt64
    ) async throws -> BackendProjectionNavigationResponse {
        guard !logicalPresentationID.isNil else {
            throw BackendProtocolError.malformedMessage
        }
        let response = try await call(
            command: "claim-projection-navigation-v2",
            parameters: [
                "logical_presentation_id": .string(
                    logicalPresentationID.uuidString.lowercased()
                ),
                "daemon_instance_id": .string(authority.daemonInstanceID.description),
                "session_id": .string(authority.sessionID.description),
                "expected_topology_revision": .unsignedInteger(expectedTopologyRevision),
            ],
            as: BackendProjectionNavigationResponse.self
        )
        return try response.validatedClaim(
            logicalPresentationID: logicalPresentationID,
            expectedAuthority: authority,
            expectedTopologyRevision: expectedTopologyRevision
        )
    }
}

extension BackendProtocolClient {
    /// Fetches one raw, revision-fenced list page.
    ///
    /// Call ``listAllProjectionNavigationV2(authority:expectedTopologyRevision:)``
    /// for bounded hydration with automatic cursor restarts.
    ///
    /// - Parameters:
    ///   - authority: The exact daemon and persisted-session authority.
    ///   - expectedTopologyRevision: The exact canonical topology revision.
    ///   - cursor: A cursor returned by the immediately preceding page, or `nil`.
    /// - Returns: One validated page or structured conflict.
    /// - Throws: A transport, decoding, or malformed-protocol error.
    func listProjectionNavigationV2Page(
        authority: BackendAuthority,
        expectedTopologyRevision: UInt64,
        cursor: BackendProjectionNavigationListCursor?
    ) async throws -> BackendProjectionNavigationResponse {
        var parameters: [String: BackendJSONValue] = [
            "daemon_instance_id": .string(authority.daemonInstanceID.description),
            "session_id": .string(authority.sessionID.description),
            "expected_topology_revision": .unsignedInteger(expectedTopologyRevision),
        ]
        if let cursor {
            parameters["cursor"] = cursor.jsonValue
        }
        let response = try await call(
            command: "list-projection-navigation-v2",
            parameters: parameters,
            as: BackendProjectionNavigationResponse.self
        )
        return try response.validatedListPage(
            expectedAuthority: authority,
            expectedTopologyRevision: expectedTopologyRevision,
            requestCursor: cursor
        )
    }
}

public extension BackendProtocolClient {
    /// Lists every retained logical window through a bounded, restartable snapshot.
    ///
    /// Every attempt starts with a `nil` cursor. A stale cursor or expired list
    /// snapshot discards partial pages and makes at most three complete attempts. The
    /// daemon bounds one client to 64 records, so this client accepts at most
    /// 65 pages per attempt and never accumulates more than 64 unique records.
    ///
    /// - Parameters:
    ///   - authority: The exact daemon and persisted-session authority.
    ///   - expectedTopologyRevision: The exact canonical topology revision.
    /// - Returns: One consolidated final response or the terminal structured conflict.
    /// - Throws: A transport, decoding, or malformed-protocol error.
    func listAllProjectionNavigationV2(
        authority: BackendAuthority,
        expectedTopologyRevision: UInt64
    ) async throws -> BackendProjectionNavigationResponse {
        var attemptCount = 0

        restart: while true {
            guard attemptCount < 3 else {
                throw BackendProtocolError.malformedMessage
            }
            attemptCount += 1
            var cursor: BackendProjectionNavigationListCursor? = nil
            var clientRevision: UInt64? = nil
            var states: [BackendProjectionNavigationState] = []
            var seenLogicalPresentationIDs: Set<UUID> = []

            for _ in 0 ..< 65 {
                let response = try await listProjectionNavigationV2Page(
                    authority: authority,
                    expectedTopologyRevision: expectedTopologyRevision,
                    cursor: cursor
                )
                switch response {
                case .conflict(let conflict) where conflict.requiresListRestart:
                    guard attemptCount < 3 else { return response }
                    continue restart
                case .conflict:
                    return response
                case .applied(let page):
                    guard let pageClientRevision = page.clientRevision,
                          clientRevision == nil || clientRevision == pageClientRevision
                    else {
                        throw BackendProtocolError.malformedMessage
                    }
                    clientRevision = pageClientRevision
                    for state in page.states {
                        guard seenLogicalPresentationIDs.insert(
                            state.logicalPresentationID
                        ).inserted,
                        states.last?.logicalPresentationID.isStrictlyBefore(
                            state.logicalPresentationID
                        ) != false,
                        states.count < 64
                        else {
                            throw BackendProtocolError.malformedMessage
                        }
                        states.append(state)
                    }
                    guard let nextCursor = page.nextCursor else {
                        return .applied(BackendProjectionNavigationApplied(
                            topologyRevision: expectedTopologyRevision,
                            clientRevision: pageClientRevision,
                            states: states
                        ))
                    }
                    cursor = nextCursor
                }
            }
            throw BackendProtocolError.malformedMessage
        }
    }

    /// Applies an idempotent atomic mutation across claimed logical windows.
    ///
    /// - Parameters:
    ///   - requestID: The UUID identifying this exact retryable request body.
    ///   - authority: The exact daemon and persisted-session authority.
    ///   - expectedTopologyRevision: The exact canonical topology revision.
    ///   - projections: Unique logical-window mutations applied atomically.
    /// - Returns: A typed applied response or structured conflict.
    /// - Throws: A transport, decoding, or malformed-protocol error.
    func mutateProjectionNavigationV2(
        requestID: UUID,
        authority: BackendAuthority,
        expectedTopologyRevision: UInt64,
        projections: [BackendProjectionNavigationMutation]
    ) async throws -> BackendProjectionNavigationResponse {
        let identifiers = projections.map(\.logicalPresentationID)
        guard !requestID.isNil,
              !projections.isEmpty,
              projections.allSatisfy({
                  !$0.logicalPresentationID.isNil
                    && !$0.claimID.isNil
                    && $0.operations.allSatisfy(\.hasNonNilIdentities)
              }),
              Set(identifiers).count == identifiers.count
        else {
            throw BackendProtocolError.malformedMessage
        }
        let response = try await call(
            command: "mutate-projection-navigation-v2",
            parameters: [
                "request_id": .string(requestID.uuidString.lowercased()),
                "daemon_instance_id": .string(authority.daemonInstanceID.description),
                "session_id": .string(authority.sessionID.description),
                "expected_topology_revision": .unsignedInteger(expectedTopologyRevision),
                "projections": .array(projections.map(\.jsonValue)),
            ],
            as: BackendProjectionNavigationResponse.self
        )
        return try response.validatedMutation(
            logicalPresentationIDs: Set(identifiers),
            claimIDs: Dictionary(uniqueKeysWithValues: projections.map {
                ($0.logicalPresentationID, $0.claimID)
            }),
            expectedGenerations: Dictionary(uniqueKeysWithValues: projections.map {
                ($0.logicalPresentationID, $0.expectedGeneration)
            }),
            expectedAuthority: authority,
            expectedTopologyRevision: expectedTopologyRevision
        )
    }

    /// Explicitly deletes one claimed logical-window record through an idempotent fence.
    ///
    /// - Parameters:
    ///   - requestID: The UUID identifying this exact retryable release body.
    ///   - logicalPresentationID: The stable logical-window identifier.
    ///   - claimID: The exact connection-owned claim.
    ///   - expectedGeneration: The record generation the caller observed.
    ///   - authority: The exact daemon and persisted-session authority.
    ///   - expectedTopologyRevision: The exact canonical topology revision.
    /// - Returns: A typed empty applied response or structured conflict.
    /// - Throws: A transport, decoding, or malformed-protocol error.
    func releaseProjectionNavigationV2(
        requestID: UUID,
        logicalPresentationID: UUID,
        claimID: UUID,
        expectedGeneration: UInt64,
        authority: BackendAuthority,
        expectedTopologyRevision: UInt64
    ) async throws -> BackendProjectionNavigationResponse {
        guard !requestID.isNil,
              !logicalPresentationID.isNil,
              !claimID.isNil
        else {
            throw BackendProtocolError.malformedMessage
        }
        let response = try await call(
            command: "release-projection-navigation-v2",
            parameters: [
                "request_id": .string(requestID.uuidString.lowercased()),
                "logical_presentation_id": .string(
                    logicalPresentationID.uuidString.lowercased()
                ),
                "claim_id": .string(claimID.uuidString.lowercased()),
                "expected_generation": .unsignedInteger(expectedGeneration),
                "daemon_instance_id": .string(authority.daemonInstanceID.description),
                "session_id": .string(authority.sessionID.description),
                "expected_topology_revision": .unsignedInteger(expectedTopologyRevision),
            ],
            as: BackendProjectionNavigationResponse.self
        )
        return try response.validatedRelease(
            expectedAuthority: authority,
            expectedTopologyRevision: expectedTopologyRevision
        )
    }
}

private extension BackendProjectionNavigationResponse {
    func validatedClaim(
        logicalPresentationID: UUID,
        expectedAuthority: BackendAuthority,
        expectedTopologyRevision: UInt64
    ) throws -> Self {
        try validateConflict(
            expectedAuthority: expectedAuthority,
            expectedTopologyRevision: expectedTopologyRevision
        )
        guard case .applied(let applied) = self else { return self }
        try applied.validateCommon(expectedTopologyRevision: expectedTopologyRevision)
        guard applied.clientRevision == nil,
              applied.nextCursor == nil,
              applied.states.count == 1,
              applied.states[0].logicalPresentationID == logicalPresentationID,
              applied.states[0].claimID != nil,
              applied.states[0].claimedProcessInstanceID != nil
        else {
            throw BackendProtocolError.malformedMessage
        }
        return self
    }

    func validatedMutation(
        logicalPresentationIDs: Set<UUID>,
        claimIDs: [UUID: UUID],
        expectedGenerations: [UUID: UInt64],
        expectedAuthority: BackendAuthority,
        expectedTopologyRevision: UInt64
    ) throws -> Self {
        try validateConflict(
            expectedAuthority: expectedAuthority,
            expectedTopologyRevision: expectedTopologyRevision
        )
        guard case .applied(let applied) = self else { return self }
        try applied.validateCommon(expectedTopologyRevision: expectedTopologyRevision)
        let responseIDs = Set(applied.states.map(\.logicalPresentationID))
        guard applied.clientRevision == nil,
              applied.nextCursor == nil,
              responseIDs.count == applied.states.count,
              responseIDs == logicalPresentationIDs,
              applied.states.allSatisfy({ state in
                  guard let claimID = claimIDs[state.logicalPresentationID],
                        let expectedGeneration = expectedGenerations[
                            state.logicalPresentationID
                        ],
                        state.claimID == claimID,
                        state.claimedProcessInstanceID != nil
                  else { return false }
                  return state.generation == expectedGeneration
                    || (
                        expectedGeneration < UInt64.max
                            && state.generation == expectedGeneration + 1
                    )
              })
        else {
            throw BackendProtocolError.malformedMessage
        }
        return self
    }

    func validatedRelease(
        expectedAuthority: BackendAuthority,
        expectedTopologyRevision: UInt64
    ) throws -> Self {
        try validateConflict(
            expectedAuthority: expectedAuthority,
            expectedTopologyRevision: expectedTopologyRevision
        )
        guard case .applied(let applied) = self else { return self }
        try applied.validateCommon(expectedTopologyRevision: expectedTopologyRevision)
        guard applied.clientRevision == nil,
              applied.nextCursor == nil,
              applied.states.isEmpty
        else {
            throw BackendProtocolError.malformedMessage
        }
        return self
    }

    func validatedListPage(
        expectedAuthority: BackendAuthority,
        expectedTopologyRevision: UInt64,
        requestCursor: BackendProjectionNavigationListCursor?
    ) throws -> Self {
        try validateConflict(
            expectedAuthority: expectedAuthority,
            expectedTopologyRevision: expectedTopologyRevision
        )
        guard case .applied(let applied) = self else { return self }
        try applied.validateCommon(expectedTopologyRevision: expectedTopologyRevision)
        guard let clientRevision = applied.clientRevision,
              requestCursor == nil || requestCursor?.clientRevision == clientRevision,
              applied.states.count <= 64,
              applied.states.haveStrictlyIncreasingLogicalPresentationIDs
        else {
            throw BackendProtocolError.malformedMessage
        }
        if let requestCursor,
           let first = applied.states.first,
           !requestCursor.afterLogicalPresentationID.isStrictlyBefore(
               first.logicalPresentationID
           ) {
            throw BackendProtocolError.malformedMessage
        }
        if let nextCursor = applied.nextCursor {
            guard nextCursor.clientRevision == clientRevision,
                  let finalID = applied.states.last?.logicalPresentationID,
                  nextCursor.afterLogicalPresentationID == finalID,
                  requestCursor?.afterLogicalPresentationID.isStrictlyBefore(finalID) != false
            else {
                throw BackendProtocolError.malformedMessage
            }
        }
        return self
    }

    func validateConflict(
        expectedAuthority: BackendAuthority,
        expectedTopologyRevision: UInt64
    ) throws {
        guard case .conflict(let conflict) = self else { return }
        guard conflict.hasValidShape(
            expectedAuthority: expectedAuthority,
            expectedTopologyRevision: expectedTopologyRevision
        ) else {
            throw BackendProtocolError.malformedMessage
        }
    }
}

private extension BackendProjectionNavigationConflict {
    func hasValidShape(
        expectedAuthority requestAuthority: BackendAuthority,
        expectedTopologyRevision requestTopologyRevision: UInt64
    ) -> Bool {
        switch self {
        case .staleTopology(
            let expectedAuthority,
            let currentAuthority,
            let expectedRevision,
            let currentRevision
        ):
            return expectedAuthority == requestAuthority
                && expectedRevision == requestTopologyRevision
                && !expectedAuthority.daemonInstanceID.rawValue.isNil
                && !expectedAuthority.sessionID.rawValue.isNil
                && !currentAuthority.daemonInstanceID.rawValue.isNil
                && !currentAuthority.sessionID.rawValue.isNil
                && (currentAuthority != expectedAuthority || currentRevision != expectedRevision)
        case .staleGeneration(
            let logicalPresentationID,
            let expected,
            let current,
            let currentState
        ):
            return !logicalPresentationID.isNil
                && expected != current
                && currentState.logicalPresentationID == logicalPresentationID
                && currentState.generation == current
                && currentState.claimID != nil
                && currentState.claimedProcessInstanceID != nil
                && currentState.hasValidShape(
                    reconciledTopologyRevision: requestTopologyRevision
                )
        case .legacyStaleGeneration(
            let logicalPresentationID,
            let expected,
            let current,
            let currentState
        ):
            return !logicalPresentationID.isNil
                && expected != current
                && currentState.logicalPresentationID == logicalPresentationID
                && currentState.generation == current
                && currentState.claimID != nil
                && currentState.claimedProcessInstanceID != nil
                && currentState.hasValidLegacyShape
        case .claimLost(let logicalPresentationID, let claimedProcessInstanceID):
            return !logicalPresentationID.isNil
                && claimedProcessInstanceID?.isNil != true
        case .workspaceOwned(let workspaceID, let ownerLogicalPresentationID):
            return !workspaceID.rawValue.isNil && !ownerLogicalPresentationID.isNil
        case .entityMissing(_, let entityID):
            return !entityID.isNil
        case .ancestryMismatch(
            _,
            let entityID,
            _,
            let expectedParentID,
            let actualParentID
        ):
            return !entityID.isNil
                && !expectedParentID.isNil
                && actualParentID?.isNil != true
        case .schemaPromoted(let logicalPresentationID, let requiredCapability):
            return !logicalPresentationID.isNil
                && requiredCapability == "projection-navigation-v2"
        case .clientSchemaPromoted(let requiredCapability):
            return requiredCapability == "projection-navigation-v2"
        case .limitExceeded(_, let maximum, let attempted):
            return attempted > maximum
        case .duplicateTarget(_, let entityID):
            return !entityID.isNil
        case .invalidSelection(_, let reason):
            return !reason.isEmpty
        case .invalidIdentity(let field):
            return !field.isEmpty
        case .requestIDReused(let requestID):
            return !requestID.isNil
        case .staleListCursor(let expectedClientRevision, let currentClientRevision):
            return expectedClientRevision != currentClientRevision
        case .invalidListCursor(let afterLogicalPresentationID):
            return !afterLogicalPresentationID.isNil
        case .listCursorRestartRequired:
            return true
        case .clientRevisionExhausted:
            return true
        case .generationExhausted(let logicalPresentationID):
            return !logicalPresentationID.isNil
        }
    }
}

private extension BackendProjectionNavigationApplied {
    func validateCommon(expectedTopologyRevision: UInt64) throws {
        guard topologyRevision == expectedTopologyRevision,
              states.allSatisfy({
                  $0.hasValidShape(reconciledTopologyRevision: expectedTopologyRevision)
              })
        else {
            throw BackendProtocolError.malformedMessage
        }
    }
}

private extension BackendProjectionState {
    var hasValidLegacyShape: Bool {
        guard !logicalPresentationID.isNil,
              (claimID == nil) == (claimedProcessInstanceID == nil),
              claimID?.isNil != true,
              claimedProcessInstanceID?.isNil != true,
              Set(workspaces.map(\.workspaceID)).count == workspaces.count,
              Set(workspaces.map(\.selectedScreenID)).count == workspaces.count,
              workspaces.allSatisfy({
                  !$0.workspaceID.rawValue.isNil && !$0.selectedScreenID.rawValue.isNil
              })
        else { return false }
        return true
    }
}

private extension BackendProjectionNavigationState {
    func hasValidShape(reconciledTopologyRevision: UInt64) -> Bool {
        guard schemaVersion == 2,
              !logicalPresentationID.isNil,
              self.reconciledTopologyRevision == reconciledTopologyRevision,
              (claimID == nil) == (claimedProcessInstanceID == nil),
              claimID?.isNil != true,
              claimedProcessInstanceID?.isNil != true,
              Set(workspaces.map(\.workspaceID)).count == workspaces.count,
              workspaces.allSatisfy({ !$0.workspaceID.rawValue.isNil }),
              selectedWorkspaceID?.rawValue.isNil != true,
              selectedWorkspaceID == nil
                || workspaces.contains(where: { $0.workspaceID == selectedWorkspaceID })
        else { return false }

        var screenIDs: Set<ScreenID> = []
        var paneIDs: Set<PaneID> = []
        var surfaceIDs: Set<SurfaceID> = []
        for workspace in workspaces {
            guard !workspace.selectedScreenID.rawValue.isNil,
                  workspace.screens.contains(where: {
                      $0.screenID == workspace.selectedScreenID
                  })
            else { return false }
            for screen in workspace.screens {
                guard !screen.screenID.rawValue.isNil,
                      screenIDs.insert(screen.screenID).inserted,
                      !screen.activePaneID.rawValue.isNil,
                      screen.zoomedPaneID?.rawValue.isNil != true,
                      screen.panes.contains(where: { $0.paneID == screen.activePaneID }),
                      screen.zoomedPaneID == nil
                        || screen.zoomedPaneID == screen.activePaneID
                else { return false }
                for pane in screen.panes {
                    guard !pane.paneID.rawValue.isNil,
                          !pane.selectedSurfaceID.rawValue.isNil,
                          paneIDs.insert(pane.paneID).inserted,
                          surfaceIDs.insert(pane.selectedSurfaceID).inserted
                    else { return false }
                }
            }
        }
        return true
    }
}

private extension Array where Element == BackendProjectionNavigationState {
    var haveStrictlyIncreasingLogicalPresentationIDs: Bool {
        guard count > 1 else { return true }
        for index in indices.dropFirst() {
            guard self[index - 1].logicalPresentationID.isStrictlyBefore(
                self[index].logicalPresentationID
            ) else { return false }
        }
        return true
    }
}

private extension BackendProjectionNavigationListCursor {
    var jsonValue: BackendJSONValue {
        .object([
            "client_revision": .unsignedInteger(clientRevision),
            "after_logical_presentation_id": .string(
                afterLogicalPresentationID.uuidString.lowercased()
            ),
        ])
    }
}

private extension BackendProjectionNavigationMutation {
    var jsonValue: BackendJSONValue {
        .object([
            "logical_presentation_id": .string(
                logicalPresentationID.uuidString.lowercased()
            ),
            "claim_id": .string(claimID.uuidString.lowercased()),
            "expected_generation": .unsignedInteger(expectedGeneration),
            "operations": .array(operations.map(\.jsonValue)),
        ])
    }
}

private extension BackendProjectionNavigationOperation {
    var hasNonNilIdentities: Bool {
        switch self {
        case .assignWorkspace(let workspaceID), .unassignWorkspace(let workspaceID):
            !workspaceID.rawValue.isNil
        case .selectWorkspace(let workspaceID):
            workspaceID?.rawValue.isNil != true
        case .selectScreen(let workspaceID, let screenID):
            !workspaceID.rawValue.isNil && !screenID.rawValue.isNil
        case .activatePane(let workspaceID, let screenID, let paneID):
            !workspaceID.rawValue.isNil && !screenID.rawValue.isNil && !paneID.rawValue.isNil
        case .setZoomedPane(let workspaceID, let screenID, let paneID):
            !workspaceID.rawValue.isNil
                && !screenID.rawValue.isNil
                && paneID?.rawValue.isNil != true
        case .selectSurface(let workspaceID, let screenID, let paneID, let surfaceID):
            !workspaceID.rawValue.isNil
                && !screenID.rawValue.isNil
                && !paneID.rawValue.isNil
                && !surfaceID.rawValue.isNil
        }
    }

    var jsonValue: BackendJSONValue {
        switch self {
        case .assignWorkspace(let workspaceID):
            .object([
                "type": .string("assign-workspace"),
                "workspace_uuid": .string(workspaceID.description),
            ])
        case .unassignWorkspace(let workspaceID):
            .object([
                "type": .string("unassign-workspace"),
                "workspace_uuid": .string(workspaceID.description),
            ])
        case .selectWorkspace(let workspaceID):
            .object([
                "type": .string("select-workspace"),
                "workspace_uuid": workspaceID.map { .string($0.description) } ?? .null,
            ])
        case .selectScreen(let workspaceID, let screenID):
            .object([
                "type": .string("select-screen"),
                "workspace_uuid": .string(workspaceID.description),
                "screen_uuid": .string(screenID.description),
            ])
        case .activatePane(let workspaceID, let screenID, let paneID):
            .object([
                "type": .string("activate-pane"),
                "workspace_uuid": .string(workspaceID.description),
                "screen_uuid": .string(screenID.description),
                "pane_uuid": .string(paneID.description),
            ])
        case .setZoomedPane(let workspaceID, let screenID, let paneID):
            .object([
                "type": .string("set-zoomed-pane"),
                "workspace_uuid": .string(workspaceID.description),
                "screen_uuid": .string(screenID.description),
                "pane_uuid": paneID.map { .string($0.description) } ?? .null,
            ])
        case .selectSurface(let workspaceID, let screenID, let paneID, let surfaceID):
            .object([
                "type": .string("select-surface"),
                "workspace_uuid": .string(workspaceID.description),
                "screen_uuid": .string(screenID.description),
                "pane_uuid": .string(paneID.description),
                "surface_uuid": .string(surfaceID.description),
            ])
        }
    }
}

private extension UUID {
    var isNil: Bool { self == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }

    func isStrictlyBefore(_ other: UUID) -> Bool {
        uuidString.lowercased() < other.uuidString.lowercased()
    }
}
