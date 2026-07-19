public import Foundation

/// A typed projection-navigation rejection returned inside a successful command envelope.
public enum BackendProjectionNavigationConflict: Codable, Equatable, Sendable {
    /// The request named a stale daemon, session, or topology revision.
    case staleTopology(
        expectedAuthority: BackendAuthority,
        currentAuthority: BackendAuthority,
        expectedRevision: UInt64,
        currentRevision: UInt64
    )

    /// A v2 record generation changed, with the current state included for reconciliation.
    case staleGeneration(
        logicalPresentationID: UUID,
        expected: UInt64,
        current: UInt64,
        currentState: BackendProjectionNavigationState
    )

    /// A legacy record generation changed before v2 schema promotion completed.
    case legacyStaleGeneration(
        logicalPresentationID: UUID,
        expected: UInt64,
        current: UInt64,
        currentState: BackendProjectionState
    )

    /// The connection no longer owns the named logical-window claim.
    case claimLost(logicalPresentationID: UUID, claimedProcessInstanceID: UUID?)

    /// Another logical window already owns the named workspace.
    case workspaceOwned(workspaceID: WorkspaceID, ownerLogicalPresentationID: UUID)

    /// A named canonical entity no longer exists.
    case entityMissing(entityKind: BackendProjectionNavigationEntityKind, entityID: UUID)

    /// A named entity does not descend from the supplied canonical parent.
    case ancestryMismatch(
        entityKind: BackendProjectionNavigationEntityKind,
        entityID: UUID,
        parentKind: BackendProjectionNavigationEntityKind,
        expectedParentID: UUID,
        actualParentID: UUID?
    )

    /// One logical record has already been promoted to the named capability.
    case schemaPromoted(logicalPresentationID: UUID, requiredCapability: String)

    /// The stable client has already established a v2 schema floor.
    case clientSchemaPromoted(requiredCapability: String)

    /// A bounded registry resource would exceed its maximum.
    case limitExceeded(
        limit: BackendProjectionNavigationLimit,
        maximum: UInt64,
        attempted: UInt64
    )

    /// One request targets the same entity or logical selection more than once.
    case duplicateTarget(entityKind: BackendProjectionNavigationEntityKind, entityID: UUID)

    /// A selection is absent from, or inconsistent with, its retained assignment.
    case invalidSelection(entityKind: BackendProjectionNavigationEntityKind, reason: String)

    /// An identity field used an invalid UUID value.
    case invalidIdentity(field: String)

    /// An idempotency UUID was reused for a different request body.
    case requestIDReused(requestID: UUID)

    /// The listed client state changed after the cursor was issued.
    case staleListCursor(expectedClientRevision: UInt64, currentClientRevision: UInt64)

    /// The cursor's final logical-window identifier is not in the snapshot.
    case invalidListCursor(afterLogicalPresentationID: UUID)

    /// The daemon no longer retains the cursor's list snapshot.
    case listCursorRestartRequired(currentClientRevision: UInt64)

    /// The daemon cannot advance the stable client's list revision.
    case clientRevisionExhausted

    /// The daemon cannot advance one logical-window generation.
    case generationExhausted(logicalPresentationID: UUID)

    /// Whether a paginated list should discard partial pages and restart from `nil`.
    var requiresListRestart: Bool {
        switch self {
        case .staleListCursor, .listCursorRestartRequired:
            true
        default:
            false
        }
    }

    /// Decodes one structured conflict using its kebab-case `code` discriminator.
    ///
    /// - Parameter decoder: The decoder containing the conflict object.
    /// - Throws: A decoding error for an unknown code or missing case field.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Code.self, forKey: .code) {
        case .staleTopology:
            self = .staleTopology(
                expectedAuthority: BackendAuthority(
                    daemonInstanceID: try container.decode(
                        DaemonInstanceID.self,
                        forKey: .expectedDaemonInstanceID
                    ),
                    sessionID: try container.decode(SessionID.self, forKey: .expectedSessionID)
                ),
                currentAuthority: BackendAuthority(
                    daemonInstanceID: try container.decode(
                        DaemonInstanceID.self,
                        forKey: .currentDaemonInstanceID
                    ),
                    sessionID: try container.decode(SessionID.self, forKey: .currentSessionID)
                ),
                expectedRevision: try container.decode(UInt64.self, forKey: .expectedRevision),
                currentRevision: try container.decode(UInt64.self, forKey: .currentRevision)
            )
        case .staleGeneration:
            self = .staleGeneration(
                logicalPresentationID: try container.decode(
                    UUID.self,
                    forKey: .logicalPresentationID
                ),
                expected: try container.decode(UInt64.self, forKey: .expected),
                current: try container.decode(UInt64.self, forKey: .current),
                currentState: try container.decode(
                    BackendProjectionNavigationState.self,
                    forKey: .currentState
                )
            )
        case .legacyStaleGeneration:
            self = .legacyStaleGeneration(
                logicalPresentationID: try container.decode(
                    UUID.self,
                    forKey: .logicalPresentationID
                ),
                expected: try container.decode(UInt64.self, forKey: .expected),
                current: try container.decode(UInt64.self, forKey: .current),
                currentState: try container.decode(BackendProjectionState.self, forKey: .currentState)
            )
        case .claimLost:
            self = .claimLost(
                logicalPresentationID: try container.decode(
                    UUID.self,
                    forKey: .logicalPresentationID
                ),
                claimedProcessInstanceID: try container.decodeIfPresent(
                    UUID.self,
                    forKey: .claimedProcessInstanceID
                )
            )
        case .workspaceOwned:
            self = .workspaceOwned(
                workspaceID: try container.decode(WorkspaceID.self, forKey: .workspaceID),
                ownerLogicalPresentationID: try container.decode(
                    UUID.self,
                    forKey: .ownerLogicalPresentationID
                )
            )
        case .entityMissing:
            self = .entityMissing(
                entityKind: try container.decode(
                    BackendProjectionNavigationEntityKind.self,
                    forKey: .entityKind
                ),
                entityID: try container.decode(UUID.self, forKey: .entityID)
            )
        case .ancestryMismatch:
            self = .ancestryMismatch(
                entityKind: try container.decode(
                    BackendProjectionNavigationEntityKind.self,
                    forKey: .entityKind
                ),
                entityID: try container.decode(UUID.self, forKey: .entityID),
                parentKind: try container.decode(
                    BackendProjectionNavigationEntityKind.self,
                    forKey: .parentKind
                ),
                expectedParentID: try container.decode(UUID.self, forKey: .expectedParentID),
                actualParentID: try container.decodeIfPresent(UUID.self, forKey: .actualParentID)
            )
        case .schemaPromoted:
            self = .schemaPromoted(
                logicalPresentationID: try container.decode(
                    UUID.self,
                    forKey: .logicalPresentationID
                ),
                requiredCapability: try container.decode(String.self, forKey: .requiredCapability)
            )
        case .clientSchemaPromoted:
            self = .clientSchemaPromoted(
                requiredCapability: try container.decode(String.self, forKey: .requiredCapability)
            )
        case .limitExceeded:
            self = .limitExceeded(
                limit: try container.decode(
                    BackendProjectionNavigationLimit.self,
                    forKey: .limit
                ),
                maximum: try container.decode(UInt64.self, forKey: .maximum),
                attempted: try container.decode(UInt64.self, forKey: .attempted)
            )
        case .duplicateTarget:
            self = .duplicateTarget(
                entityKind: try container.decode(
                    BackendProjectionNavigationEntityKind.self,
                    forKey: .entityKind
                ),
                entityID: try container.decode(UUID.self, forKey: .entityID)
            )
        case .invalidSelection:
            self = .invalidSelection(
                entityKind: try container.decode(
                    BackendProjectionNavigationEntityKind.self,
                    forKey: .entityKind
                ),
                reason: try container.decode(String.self, forKey: .reason)
            )
        case .invalidIdentity:
            self = .invalidIdentity(field: try container.decode(String.self, forKey: .field))
        case .requestIDReused:
            self = .requestIDReused(
                requestID: try container.decode(UUID.self, forKey: .requestID)
            )
        case .staleListCursor:
            self = .staleListCursor(
                expectedClientRevision: try container.decode(
                    UInt64.self,
                    forKey: .expectedClientRevision
                ),
                currentClientRevision: try container.decode(
                    UInt64.self,
                    forKey: .currentClientRevision
                )
            )
        case .invalidListCursor:
            self = .invalidListCursor(
                afterLogicalPresentationID: try container.decode(
                    UUID.self,
                    forKey: .afterLogicalPresentationID
                )
            )
        case .listCursorRestartRequired:
            self = .listCursorRestartRequired(
                currentClientRevision: try container.decode(
                    UInt64.self,
                    forKey: .currentClientRevision
                )
            )
        case .clientRevisionExhausted:
            self = .clientRevisionExhausted
        case .generationExhausted:
            self = .generationExhausted(
                logicalPresentationID: try container.decode(
                    UUID.self,
                    forKey: .logicalPresentationID
                )
            )
        }
    }

    /// Encodes one structured conflict using its canonical Rust wire fields.
    ///
    /// - Parameter encoder: The encoder receiving the conflict object.
    /// - Throws: Any error raised by the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .staleTopology(
            let expectedAuthority,
            let currentAuthority,
            let expectedRevision,
            let currentRevision
        ):
            try container.encode(Code.staleTopology, forKey: .code)
            try container.encode(
                expectedAuthority.daemonInstanceID,
                forKey: .expectedDaemonInstanceID
            )
            try container.encode(
                currentAuthority.daemonInstanceID,
                forKey: .currentDaemonInstanceID
            )
            try container.encode(expectedAuthority.sessionID, forKey: .expectedSessionID)
            try container.encode(currentAuthority.sessionID, forKey: .currentSessionID)
            try container.encode(expectedRevision, forKey: .expectedRevision)
            try container.encode(currentRevision, forKey: .currentRevision)
        case .staleGeneration(
            let logicalPresentationID,
            let expected,
            let current,
            let currentState
        ):
            try container.encode(Code.staleGeneration, forKey: .code)
            try container.encode(logicalPresentationID, forKey: .logicalPresentationID)
            try container.encode(expected, forKey: .expected)
            try container.encode(current, forKey: .current)
            try container.encode(currentState, forKey: .currentState)
        case .legacyStaleGeneration(
            let logicalPresentationID,
            let expected,
            let current,
            let currentState
        ):
            try container.encode(Code.legacyStaleGeneration, forKey: .code)
            try container.encode(logicalPresentationID, forKey: .logicalPresentationID)
            try container.encode(expected, forKey: .expected)
            try container.encode(current, forKey: .current)
            try container.encode(currentState, forKey: .currentState)
        case .claimLost(let logicalPresentationID, let claimedProcessInstanceID):
            try container.encode(Code.claimLost, forKey: .code)
            try container.encode(logicalPresentationID, forKey: .logicalPresentationID)
            try container.encode(claimedProcessInstanceID, forKey: .claimedProcessInstanceID)
        case .workspaceOwned(let workspaceID, let ownerLogicalPresentationID):
            try container.encode(Code.workspaceOwned, forKey: .code)
            try container.encode(workspaceID, forKey: .workspaceID)
            try container.encode(ownerLogicalPresentationID, forKey: .ownerLogicalPresentationID)
        case .entityMissing(let entityKind, let entityID):
            try container.encode(Code.entityMissing, forKey: .code)
            try container.encode(entityKind, forKey: .entityKind)
            try container.encode(entityID, forKey: .entityID)
        case .ancestryMismatch(
            let entityKind,
            let entityID,
            let parentKind,
            let expectedParentID,
            let actualParentID
        ):
            try container.encode(Code.ancestryMismatch, forKey: .code)
            try container.encode(entityKind, forKey: .entityKind)
            try container.encode(entityID, forKey: .entityID)
            try container.encode(parentKind, forKey: .parentKind)
            try container.encode(expectedParentID, forKey: .expectedParentID)
            try container.encode(actualParentID, forKey: .actualParentID)
        case .schemaPromoted(let logicalPresentationID, let requiredCapability):
            try container.encode(Code.schemaPromoted, forKey: .code)
            try container.encode(logicalPresentationID, forKey: .logicalPresentationID)
            try container.encode(requiredCapability, forKey: .requiredCapability)
        case .clientSchemaPromoted(let requiredCapability):
            try container.encode(Code.clientSchemaPromoted, forKey: .code)
            try container.encode(requiredCapability, forKey: .requiredCapability)
        case .limitExceeded(let limit, let maximum, let attempted):
            try container.encode(Code.limitExceeded, forKey: .code)
            try container.encode(limit, forKey: .limit)
            try container.encode(maximum, forKey: .maximum)
            try container.encode(attempted, forKey: .attempted)
        case .duplicateTarget(let entityKind, let entityID):
            try container.encode(Code.duplicateTarget, forKey: .code)
            try container.encode(entityKind, forKey: .entityKind)
            try container.encode(entityID, forKey: .entityID)
        case .invalidSelection(let entityKind, let reason):
            try container.encode(Code.invalidSelection, forKey: .code)
            try container.encode(entityKind, forKey: .entityKind)
            try container.encode(reason, forKey: .reason)
        case .invalidIdentity(let field):
            try container.encode(Code.invalidIdentity, forKey: .code)
            try container.encode(field, forKey: .field)
        case .requestIDReused(let requestID):
            try container.encode(Code.requestIDReused, forKey: .code)
            try container.encode(requestID, forKey: .requestID)
        case .staleListCursor(let expectedClientRevision, let currentClientRevision):
            try container.encode(Code.staleListCursor, forKey: .code)
            try container.encode(expectedClientRevision, forKey: .expectedClientRevision)
            try container.encode(currentClientRevision, forKey: .currentClientRevision)
        case .invalidListCursor(let afterLogicalPresentationID):
            try container.encode(Code.invalidListCursor, forKey: .code)
            try container.encode(afterLogicalPresentationID, forKey: .afterLogicalPresentationID)
        case .listCursorRestartRequired(let currentClientRevision):
            try container.encode(Code.listCursorRestartRequired, forKey: .code)
            try container.encode(currentClientRevision, forKey: .currentClientRevision)
        case .clientRevisionExhausted:
            try container.encode(Code.clientRevisionExhausted, forKey: .code)
        case .generationExhausted(let logicalPresentationID):
            try container.encode(Code.generationExhausted, forKey: .code)
            try container.encode(logicalPresentationID, forKey: .logicalPresentationID)
        }
    }

    private enum Code: String, Codable {
        case staleTopology = "stale-topology"
        case staleGeneration = "stale-generation"
        case legacyStaleGeneration = "legacy-stale-generation"
        case claimLost = "claim-lost"
        case workspaceOwned = "workspace-owned"
        case entityMissing = "entity-missing"
        case ancestryMismatch = "ancestry-mismatch"
        case schemaPromoted = "schema-promoted"
        case clientSchemaPromoted = "client-schema-promoted"
        case limitExceeded = "limit-exceeded"
        case duplicateTarget = "duplicate-target"
        case invalidSelection = "invalid-selection"
        case invalidIdentity = "invalid-identity"
        case requestIDReused = "request-id-reused"
        case staleListCursor = "stale-list-cursor"
        case invalidListCursor = "invalid-list-cursor"
        case listCursorRestartRequired = "list-cursor-restart-required"
        case clientRevisionExhausted = "client-revision-exhausted"
        case generationExhausted = "generation-exhausted"
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case expectedDaemonInstanceID = "expected_daemon_instance_id"
        case currentDaemonInstanceID = "current_daemon_instance_id"
        case expectedSessionID = "expected_session_id"
        case currentSessionID = "current_session_id"
        case expectedRevision = "expected_revision"
        case currentRevision = "current_revision"
        case logicalPresentationID = "logical_presentation_id"
        case expected
        case current
        case currentState = "current_state"
        case claimedProcessInstanceID = "claimed_process_instance_uuid"
        case workspaceID = "workspace_uuid"
        case ownerLogicalPresentationID = "owner_logical_presentation_id"
        case entityKind = "entity_kind"
        case entityID = "entity_uuid"
        case parentKind = "parent_kind"
        case expectedParentID = "expected_parent_uuid"
        case actualParentID = "actual_parent_uuid"
        case requiredCapability = "required_capability"
        case limit
        case maximum
        case attempted
        case reason
        case field
        case requestID = "request_id"
        case expectedClientRevision = "expected_client_revision"
        case currentClientRevision = "current_client_revision"
        case afterLogicalPresentationID = "after_logical_presentation_id"
    }
}
