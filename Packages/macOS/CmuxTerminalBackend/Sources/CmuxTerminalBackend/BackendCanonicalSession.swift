public import Foundation

/// One fail-closed connection to the daemon-owned topology and terminal authority.
///
/// The session installs one atomic snapshot, resumes at that exact revision, and
/// publishes only contiguous deltas. A gap, authority change, overflow, or malformed
/// event closes the connection so the UI cannot combine stale state with new commands.
public actor BackendCanonicalSession {
    private static let subscriberEventCapacity = 256
    private static let maximumTerminalLeaseTTLMilliseconds: UInt64 = 30_000
    private static let maximumAutomationDelegationTTLMilliseconds: UInt64 = 10_000
    private static let terminalLeaseRefreshMarginMilliseconds: UInt64 = 1_000
    private static let ensureTerminalsCapability = "ensure-terminals-v1"
    private static let canonicalTopologyMutationsCapability = "canonical-topology-mutations-v1"
    private static let canonicalTopologyReadCapabilities: Set<String> = [
        "canonical-topology-snapshot-v1",
        "topology-resume-v1",
    ]

    private struct TerminalLeaseKey: Hashable, Sendable {
        let surfaceID: SurfaceID
        let kind: BackendTerminalLeaseKind
    }

    private struct ManagedTerminalLease: Sendable {
        var value: BackendTerminalLease
        var nextSequence: UInt64
        let ttlMilliseconds: UInt64
        var localDeadline: ContinuousClock.Instant
    }

    private let client: BackendProtocolClient
    private let transport: any BackendPeerIdentityTransport
    private let expectation: BackendCanonicalSessionExpectation
    private let handshakePolicy: BackendHandshakePolicy
    private let registrationIdentity: BackendClientRegistrationIdentity
    private let clock = ContinuousClock()
    private var projection = TopologyProjection<CanonicalTopology>()
    private var activityProjection = BackendTerminalActivityProjection()
    private var eventTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<BackendCanonicalSessionEvent>.Continuation] = [:]
    private var connected = false
    private var terminalError: BackendCanonicalSessionError?
    private var identifiedBackend: BackendIdentifyResponse?
    private var negotiatedCompatibility: BackendCompatibilityResult?
    private var advertisedCapabilities: Set<String> = []
    private var negotiatedTerminalControl: BackendTerminalControlProtocol?
    private var clientRegistration: BackendClientRegistration?
    private var topologyMutationLease: BackendTopologyMutationLease?
    private var terminalLeases: [TerminalLeaseKey: ManagedTerminalLease] = [:]
    private var terminalOperationsInFlight: Set<TerminalLeaseKey> = []
    private var terminalOperationWaiters: [
        TerminalLeaseKey: [CheckedContinuation<Void, Never>]
    ] = [:]

    /// Creates a session over one credential-bearing transport.
    public init(
        transport: any BackendPeerIdentityTransport,
        expectation: BackendCanonicalSessionExpectation,
        registrationIdentity: BackendClientRegistrationIdentity,
        handshakePolicy: BackendHandshakePolicy = .terminalAuthorityV1,
        eventCapacity: Int = BackendProtocolClient.defaultEventCapacity
    ) {
        self.transport = transport
        client = BackendProtocolClient(transport: transport, eventCapacity: eventCapacity)
        self.expectation = expectation
        self.registrationIdentity = registrationIdentity
        self.handshakePolicy = handshakePolicy
    }

    /// Returns a newest-state stream, seeded immediately when already connected.
    public func events() -> AsyncStream<BackendCanonicalSessionEvent> {
        let identifier = UUID()
        let pair = AsyncStream<BackendCanonicalSessionEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.subscriberEventCapacity)
        )
        continuations[identifier] = pair.continuation
        if let snapshot = currentSnapshot() {
            pair.continuation.yield(.snapshot(snapshot))
            if let activity = currentTerminalActivitySnapshot() {
                pair.continuation.yield(.terminalActivitySnapshot(activity))
            }
        } else if let terminalError {
            pair.continuation.yield(.disconnected(terminalError))
        }
        pair.continuation.onTermination = { @Sendable _ in
            Task { await self.removeContinuation(identifier) }
        }
        return pair.stream
    }

    /// Connects and validates identity, then installs canonical topology only
    /// when a mutually understood observational contract is advertised.
    ///
    /// Diagnostic-only compatibility returns `nil` while retaining the live
    /// identify-first connection and rejecting every mutation locally.
    @discardableResult
    public func connect() async throws -> TopologySnapshot? {
        guard !connected, eventTask == nil else {
            throw BackendCanonicalSessionError.alreadyConnected
        }
        terminalError = nil
        identifiedBackend = nil
        negotiatedCompatibility = nil
        advertisedCapabilities.removeAll()
        activityProjection.invalidate()
        resetTerminalControlState()
        do {
            try await client.connect()
            let actualPeerIdentity = try await transport.peerIdentity()
            if let expectedPeerIdentity = expectation.peerIdentity,
               actualPeerIdentity != expectedPeerIdentity {
                throw BackendCanonicalSessionError.unexpectedPeerIdentity(
                    expected: expectedPeerIdentity,
                    actual: actualPeerIdentity
                )
            }
            let identify = try await client.identify()
            let compatibility = try handshakePolicy.validate(identify)
            try validateIdentity(identify)
            try await client.installCompatibility(compatibility)
            if case .readWrite(let readWrite) = compatibility {
                try await negotiateTerminalControl(
                    protocolVersion: readWrite.negotiatedProtocol,
                    identify: identify
                )
            }

            let stream = await client.events()
            let mayReadCanonicalTopology = compatibility.negotiatedProtocol != nil
                && identify.capabilities.isSuperset(
                    of: Self.canonicalTopologyReadCapabilities
                )
            guard mayReadCanonicalTopology else {
                advertisedCapabilities = identify.capabilities
                identifiedBackend = identify
                negotiatedCompatibility = compatibility
                connected = true
                startEventTask(stream, applyCanonicalEvents: false)
                return nil
            }

            let snapshot = try await client.topologySnapshot()
            guard snapshot.authority == identify.authority else {
                throw BackendCanonicalSessionError.snapshotAuthorityMismatch(
                    expected: identify.authority,
                    actual: snapshot.authority
                )
            }
            projection.install(snapshot: snapshot)

            let subscription = try await client.subscribeTopology(
                authority: snapshot.authority,
                revision: snapshot.revision
            )
            switch subscription {
            case .resnapshotRequired(let required):
                throw BackendCanonicalSessionError.resnapshotRequired(required.reason)
            case .subscribed(let accepted):
                guard accepted.authority == snapshot.authority else {
                    throw BackendCanonicalSessionError.subscriptionAuthorityMismatch(
                        expected: snapshot.authority,
                        actual: accepted.authority
                    )
                }
                guard accepted.fromRevision == snapshot.revision else {
                    throw BackendCanonicalSessionError.subscriptionCursorMismatch(
                        expected: snapshot.revision,
                        actual: accepted.fromRevision
                    )
                }
            }
            if case .readWrite = compatibility {
                guard let readerUUID = clientRegistration?.clientUUID else {
                    throw BackendTerminalControlError.registrationIdentityMismatch
                }
                let activity = try await client.terminalActivitySnapshot()
                try activityProjection.install(activity, expectedReaderUUID: readerUUID)
            }
            advertisedCapabilities = identify.capabilities
            identifiedBackend = identify
            negotiatedCompatibility = compatibility
            connected = true
            publish(.snapshot(snapshot))
            if let activity = currentTerminalActivitySnapshot() {
                publish(.terminalActivitySnapshot(activity))
            }
            startEventTask(stream, applyCanonicalEvents: true)
            return snapshot
        } catch {
            projection.invalidate()
            identifiedBackend = nil
            negotiatedCompatibility = nil
            advertisedCapabilities.removeAll()
            activityProjection.invalidate()
            resetTerminalControlState()
            await client.close()
            if let sessionError = error as? BackendCanonicalSessionError {
                terminalError = sessionError
                publish(.disconnected(sessionError))
            }
            throw error
        }
    }

    /// The latest topology paired atomically with its authority and revision.
    public func currentSnapshot() -> TopologySnapshot? {
        guard let authority = projection.authority,
              let revision = projection.revision,
              let topology = projection.value
        else { return nil }
        return TopologySnapshot(authority: authority, revision: revision, topology: topology)
    }

    /// Returns persisted activity facts and receipts for this stable frontend reader.
    public func currentTerminalActivitySnapshot() -> BackendTerminalActivitySnapshot? {
        activityProjection.snapshot(liveSurfaceIDs: projection.value?.liveSurfaceIDs)
    }

    /// Binds one snapshot expectation to the server-issued lease for this live connection.
    public func makeTopologyMutationExpectation(
        requestID: UUID,
        authority: BackendAuthority,
        revision: UInt64
    ) async throws -> BackendTopologyMutationExpectation {
        try requireCanonicalTopologyMutation(command: "canonical-topology-mutation")
        try requireNonNil(requestID)
        guard projection.authority == authority,
              projection.revision == revision
        else {
            throw BackendProtocolError.invalidTopology(
                "canonical topology mutation expectation is not the current installed snapshot"
            )
        }
        guard let registration = clientRegistration,
              let topologyMutationLease,
              topologyMutationLease.connectionID == registration.connectionID
        else {
            throw BackendTerminalControlError.protocolNotNegotiated
        }
        return BackendTopologyMutationExpectation(
            requestID: requestID,
            authority: authority,
            revision: revision,
            topologyLease: topologyMutationLease
        )
    }

    /// Durably marks one activity sequence as observed by this stable frontend reader.
    @discardableResult
    public func markTerminalSeen(
        surfaceID: SurfaceID,
        activitySequence: UInt64
    ) async throws -> BackendTerminalActivityReceipt {
        try requireConnected()
        try requireMutationAccess(command: "mark-terminal-seen")
        try requireLeasedProtocol()
        guard activitySequence > 0,
              projection.value?.liveSurfaceIDs.contains(surfaceID) == true
        else {
            throw BackendProtocolError.malformedMessage
        }
        let receipt = try await client.markTerminalSeen(
            surfaceID: surfaceID,
            activitySequence: activitySequence
        )
        if try activityProjection.apply(receipt) {
            publish(.terminalActivityReceipt(receipt))
        }
        return receipt
    }

    /// Returns the canonical surface matching one daemon-local handle.
    public func surface(handle: UInt64) -> CanonicalSurface? {
        projection.value?.surface(handle: handle)
    }

    /// Returns the identify response retained for this exact live connection.
    public func backendIdentity() throws -> BackendIdentifyResponse {
        try requireConnected()
        guard let identifiedBackend else { throw BackendProtocolError.malformedMessage }
        return identifiedBackend
    }

    /// Returns explicit read-write authority or the complete read-only diagnostic.
    public func compatibility() throws -> BackendCompatibilityResult {
        try requireConnected()
        guard let negotiatedCompatibility else { throw BackendProtocolError.malformedMessage }
        return negotiatedCompatibility
    }

    public func backendCompatibility() async throws -> BackendCompatibilityResult {
        try compatibility()
    }

    /// Reads a lightweight authority and process health proof.
    public func health() async throws -> BackendHealthResponse {
        try requireConnected()
        return try await client.health()
    }

    /// Lists connection-owned presentations for diagnostics.
    public func listPresentations() async throws -> [BackendPresentation] {
        try requireConnected()
        return try await client.listPresentations()
    }

    /// Closes only this frontend connection. Backend-owned PTYs remain alive.
    public func close() async {
        eventTask?.cancel()
        eventTask = nil
        connected = false
        projection.invalidate()
        terminalError = nil
        identifiedBackend = nil
        negotiatedCompatibility = nil
        advertisedCapabilities.removeAll()
        activityProjection.invalidate()
        resetTerminalControlState()
        await client.close()
        finishContinuations()
    }

    /// Creates the first terminal in a new backend workspace.
    public func newWorkspace(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        name: String? = nil,
        launch: BackendTerminalLaunch = BackendTerminalLaunch(),
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) async throws -> BackendSurfacePlacement {
        try requireCanonicalTopologyMutation(expectation, command: "canonical-new-workspace")
        return try await client.canonicalNewWorkspace(
            expectation: expectation,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            name: name,
            launch: launch,
            columns: columns,
            rows: rows
        )
    }

    /// Idempotently creates or reattaches one stable caller-identified terminal.
    public func ensureTerminal(
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
    ) async throws -> BackendEnsuredTerminalPlacement {
        try requireConnected()
        try requireMutationAccess(command: "ensure-terminal")
        return try await client.ensureTerminal(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
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

    /// Resolves or creates a bounded cold terminal set, using one canonical
    /// transaction when the daemon advertises batch support and ordered
    /// singular requests for an older compatible daemon.
    public func ensureTerminals(
        _ requests: [BackendEnsureTerminalRequest]
    ) async throws -> [BackendEnsuredTerminalPlacement] {
        try requireConnected()
        try requireMutationAccess(command: "ensure-terminals")
        guard !requests.isEmpty else { return [] }
        guard advertisedCapabilities.contains(Self.ensureTerminalsCapability) else {
            var placements: [BackendEnsuredTerminalPlacement] = []
            placements.reserveCapacity(requests.count)
            for request in requests {
                placements.append(try await client.ensureTerminal(
                    workspaceID: request.workspaceID,
                    surfaceID: request.surfaceID,
                    workingDirectory: request.workingDirectory,
                    command: request.command,
                    arguments: request.arguments,
                    environment: request.environment,
                    initialInput: request.initialInput,
                    waitAfterCommand: request.waitAfterCommand,
                    columns: request.columns,
                    rows: request.rows
                ))
            }
            return placements
        }
        return try await client.ensureTerminals(requests)
    }

    /// Moves one stable terminal into a workspace without replacing its PTY.
    public func reparentTerminal(
        surfaceID: SurfaceID,
        workspaceID: WorkspaceID
    ) async throws -> BackendReparentedTerminalPlacement {
        try requireConnected()
        try requireMutationAccess(command: "reparent-terminal")
        return try await client.reparentTerminal(
            surfaceID: surfaceID,
            workspaceID: workspaceID
        )
    }

    public func configureRendererPresentation(
        id: PresentationID,
        expectedGeneration: UInt64,
        configuration: BackendRendererPresentationConfiguration
    ) async throws -> BackendRendererPresentationReceipt {
        try requireConnected()
        try requireMutationAccess(command: "configure-renderer-presentation")
        return try await client.configureRendererPresentation(
            id: id,
            expectedGeneration: expectedGeneration,
            configuration: configuration
        )
    }

    public func detachRendererPresentation(
        id: PresentationID,
        expectedGeneration: UInt64
    ) async throws {
        try requireConnected()
        try requireMutationAccess(command: "detach-renderer-presentation")
        try await client.detachRendererPresentation(
            id: id,
            expectedGeneration: expectedGeneration
        )
    }

    public func setTerminalPreedit(
        presentationID: PresentationID,
        rendererGeneration: UInt64,
        text: String?
    ) async throws {
        let preedit = text.map { text in
            let end = UInt32(clamping: text.utf16.count)
            return BackendTerminalPreedit(
                text: text,
                selectionStartUTF16: end,
                selectionLengthUTF16: 0,
                caretUTF16: end
            )
        }
        try await setTerminalPreedit(
            presentationID: presentationID,
            rendererGeneration: rendererGeneration,
            preedit: preedit
        )
    }

    public func setTerminalPreedit(
        presentationID: PresentationID,
        rendererGeneration: UInt64,
        preedit: BackendTerminalPreedit?
    ) async throws {
        try requireConnected()
        try requireMutationAccess(command: "terminal-preedit")
        try await client.setTerminalPreedit(
            presentationID: presentationID,
            rendererGeneration: rendererGeneration,
            preedit: preedit
        )
    }

    public func releaseRendererFrame(
        _ release: BackendRendererFrameRelease
    ) async throws -> BackendRendererFrameReleaseResponse {
        try requireConnected()
        try requireMutationAccess(command: "release-renderer-frame")
        return try await client.releaseRendererFrame(release)
    }

    public func rendererWorkers() async throws -> BackendRendererWorkersResponse {
        try requireConnected()
        return try await client.rendererWorkers()
    }

    public func claimProjectionState(
        logicalPresentationID: UUID
    ) async throws -> BackendProjectionState {
        try requireConnected()
        try requireMutationAccess(command: "claim-projection-state")
        return try await client.claimProjectionState(
            logicalPresentationID: logicalPresentationID
        )
    }

    public func updateProjectionState(
        logicalPresentationID: UUID,
        claimID: UUID,
        expectedGeneration: UInt64,
        workspaces: [BackendProjectionWorkspaceState]
    ) async throws -> BackendProjectionState {
        try requireConnected()
        try requireMutationAccess(command: "update-projection-state")
        return try await client.updateProjectionState(
            logicalPresentationID: logicalPresentationID,
            claimID: claimID,
            expectedGeneration: expectedGeneration,
            workspaces: workspaces
        )
    }

    public func updateProjectionStates(
        _ projections: [BackendProjectionStateUpdate]
    ) async throws -> [BackendProjectionState] {
        try requireConnected()
        try requireMutationAccess(command: "update-projection-states")
        return try await client.updateProjectionStates(projections)
    }

    public func releaseProjectionState(
        logicalPresentationID: UUID,
        claimID: UUID,
        expectedGeneration: UInt64
    ) async throws {
        try requireConnected()
        try requireMutationAccess(command: "release-projection-state")
        try await client.releaseProjectionState(
            logicalPresentationID: logicalPresentationID,
            claimID: claimID,
            expectedGeneration: expectedGeneration
        )
    }

    public func listProjectionStates() async throws -> [BackendProjectionState] {
        try requireConnected()
        return try await client.listProjectionStates()
    }

    /// Returns the terminal-mutation protocol selected during this connection's handshake.
    public func terminalControlProtocol() throws -> BackendTerminalControlProtocol {
        try requireConnected()
        try requireMutationAccess(command: "terminal-control")
        guard let negotiatedTerminalControl else {
            throw BackendTerminalControlError.protocolNotNegotiated
        }
        return negotiatedTerminalControl
    }

    /// Acquires or refreshes the lease for one successfully configured presentation.
    @discardableResult
    public func acquireTerminalControl(
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        ttlMilliseconds: UInt64 = 5_000
    ) async throws -> BackendTerminalControlLease {
        try requireConnected()
        try requireMutationAccess(command: "acquire-terminal-lease")
        let inputKey = TerminalLeaseKey(surfaceID: surfaceID, kind: .input)
        let geometryKey = TerminalLeaseKey(surfaceID: surfaceID, kind: .geometry)
        await beginTerminalOperation(inputKey)
        await beginTerminalOperation(geometryKey)
        defer {
            endTerminalOperation(geometryKey)
            endTerminalOperation(inputKey)
        }
        try Task.checkCancellation()
        try requireConnected()
        let input = try await acquireTerminalLeaseWithoutSerialization(
            kind: .input,
            surfaceID: surfaceID,
            presentationID: presentationID,
            presentationGeneration: presentationGeneration,
            ttlMilliseconds: ttlMilliseconds
        )
        do {
            let geometry = try await acquireTerminalLeaseWithoutSerialization(
                kind: .geometry,
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: presentationGeneration,
                ttlMilliseconds: ttlMilliseconds
            )
            return BackendTerminalControlLease(input: input, geometry: geometry)
        } catch {
            terminalLeases.removeValue(forKey: inputKey)
            try? await client.releaseTerminalLease(input)
            throw error
        }
    }

    /// Acquires or refreshes one authority lane without implicitly claiming the other.
    @discardableResult
    public func acquireTerminalLease(
        kind: BackendTerminalLeaseKind,
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        ttlMilliseconds: UInt64 = 5_000
    ) async throws -> BackendTerminalLease {
        try requireConnected()
        try requireMutationAccess(command: "acquire-terminal-lease")
        let key = TerminalLeaseKey(surfaceID: surfaceID, kind: kind)
        await beginTerminalOperation(key)
        defer { endTerminalOperation(key) }
        try Task.checkCancellation()
        try requireConnected()

        if let existing = terminalLeases[key] {
            if existing.value.presentationID == presentationID,
               existing.value.presentationGeneration == presentationGeneration {
                return try await refreshedTerminalLeaseIfNeeded(
                    kind: kind,
                    surfaceID: surfaceID,
                    presentationID: presentationID,
                    presentationGeneration: presentationGeneration
                ).value
            }
            terminalLeases.removeValue(forKey: key)
            try? await client.releaseTerminalLease(existing.value)
        }
        return try await acquireTerminalLeaseWithoutSerialization(
            kind: kind,
            surfaceID: surfaceID,
            presentationID: presentationID,
            presentationGeneration: presentationGeneration,
            ttlMilliseconds: ttlMilliseconds
        )
    }

    /// Releases one exact lane if this session currently owns it.
    public func releaseTerminalLease(
        kind: BackendTerminalLeaseKind,
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64
    ) async throws {
        try requireConnected()
        try requireMutationAccess(command: "release-terminal-lease")
        let key = TerminalLeaseKey(surfaceID: surfaceID, kind: kind)
        await beginTerminalOperation(key)
        defer { endTerminalOperation(key) }
        try Task.checkCancellation()
        try requireConnected()
        try requireLeasedProtocol()
        guard let managed = terminalLeases[key] else { return }
        try validateLeaseClaim(
            managed.value,
            surfaceID: surfaceID,
            presentationID: presentationID,
            presentationGeneration: presentationGeneration
        )
        terminalLeases.removeValue(forKey: key)
        try await client.releaseTerminalLease(managed.value)
    }

    /// Releases the active lease matching one exact presentation claim.
    public func releaseTerminalControl(
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64
    ) async throws {
        try requireConnected()
        try requireMutationAccess(command: "release-terminal-lease")
        let inputKey = TerminalLeaseKey(surfaceID: surfaceID, kind: .input)
        let geometryKey = TerminalLeaseKey(surfaceID: surfaceID, kind: .geometry)
        await beginTerminalOperation(inputKey)
        await beginTerminalOperation(geometryKey)
        defer {
            endTerminalOperation(geometryKey)
            endTerminalOperation(inputKey)
        }
        try Task.checkCancellation()
        try requireConnected()
        try requireLeasedProtocol()
        let input = terminalLeases[inputKey]
        let geometry = terminalLeases[geometryKey]
        if let input {
            try validateLeaseClaim(
                input.value,
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: presentationGeneration
            )
        }
        if let geometry {
            try validateLeaseClaim(
                geometry.value,
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: presentationGeneration
            )
        }
        terminalLeases.removeValue(forKey: inputKey)
        terminalLeases.removeValue(forKey: geometryKey)
        var firstError: (any Error)?
        if let input {
            do {
                try await client.releaseTerminalLease(input.value)
            } catch {
                firstError = error
            }
        }
        if let geometry {
            do {
                try await client.releaseTerminalLease(geometry.value)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    /// Delegates a bounded subset of input to one exact live automation client.
    /// The delegation never carries geometry authority.
    public func grantTerminalInputDelegation(
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        delegateClientUUID: UUID,
        ttlMilliseconds: UInt64,
        scopes: Set<BackendTerminalAutomationInputScope>
    ) async throws -> BackendTerminalInputDelegation {
        try requireConnected()
        try requireMutationAccess(command: "grant-terminal-input-delegation")
        let key = TerminalLeaseKey(surfaceID: surfaceID, kind: .input)
        await beginTerminalOperation(key)
        defer { endTerminalOperation(key) }
        try Task.checkCancellation()
        try requireConnected()
        try requireNonNil(delegateClientUUID)
        guard !scopes.isEmpty else { throw BackendProtocolError.malformedMessage }
        let managed = try await refreshedTerminalLeaseIfNeeded(
            kind: .input,
            surfaceID: surfaceID,
            presentationID: presentationID,
            presentationGeneration: presentationGeneration
        )
        let ttl = min(
            max(ttlMilliseconds, 1),
            Self.maximumAutomationDelegationTTLMilliseconds
        )
        let delegation = try await client.grantTerminalInputDelegation(
            lease: managed.value,
            delegateClientUUID: delegateClientUUID,
            ttlMilliseconds: ttl,
            scopes: scopes
        )
        guard delegation.surfaceID == surfaceID,
              delegation.ownerLeaseGeneration == managed.value.leaseGeneration,
              delegation.delegateClientUUID == delegateClientUUID,
              !isNil(delegation.delegationID),
              delegation.delegationGeneration > 0,
              delegation.nextSequence > 0,
              delegation.scopes == scopes else {
            throw BackendProtocolError.malformedMessage
        }
        return delegation
    }

    public func revokeTerminalInputDelegation(
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        delegation: BackendTerminalInputDelegation
    ) async throws {
        try requireConnected()
        try requireMutationAccess(command: "revoke-terminal-input-delegation")
        let key = TerminalLeaseKey(surfaceID: surfaceID, kind: .input)
        await beginTerminalOperation(key)
        defer { endTerminalOperation(key) }
        try Task.checkCancellation()
        try requireConnected()
        guard delegation.surfaceID == surfaceID else {
            throw BackendTerminalControlError.staleLease
        }
        let managed = try await refreshedTerminalLeaseIfNeeded(
            kind: .input,
            surfaceID: surfaceID,
            presentationID: presentationID,
            presentationGeneration: presentationGeneration
        )
        try await client.revokeTerminalInputDelegation(
            lease: managed.value,
            delegation: delegation
        )
    }

    /// Transfers one lane to another exact client/presentation claim. The local
    /// session drops only that lane and can continue using the other lane.
    public func transferTerminalLease(
        kind: BackendTerminalLeaseKind,
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        targetClientUUID: UUID,
        targetPresentationID: PresentationID,
        targetPresentationGeneration: UInt64,
        ttlMilliseconds: UInt64 = 5_000
    ) async throws {
        try requireConnected()
        try requireMutationAccess(command: "transfer-terminal-lease")
        let key = TerminalLeaseKey(surfaceID: surfaceID, kind: kind)
        await beginTerminalOperation(key)
        defer { endTerminalOperation(key) }
        try Task.checkCancellation()
        try requireConnected()
        try requireNonNil(targetClientUUID)
        let managed = try await refreshedTerminalLeaseIfNeeded(
            kind: kind,
            surfaceID: surfaceID,
            presentationID: presentationID,
            presentationGeneration: presentationGeneration
        )
        let ttl = min(max(ttlMilliseconds, 1), Self.maximumTerminalLeaseTTLMilliseconds)
        let response = try await client.transferTerminalLease(
            managed.value,
            targetClientUUID: targetClientUUID,
            targetPresentationID: targetPresentationID,
            targetPresentationGeneration: targetPresentationGeneration,
            ttlMilliseconds: ttl
        )
        guard response.kind == kind,
              response.surfaceID == surfaceID,
              response.presentationID == targetPresentationID,
              response.presentationGeneration == targetPresentationGeneration,
              response.leaseGeneration > managed.value.leaseGeneration,
              response.nextSequence > 0 else {
            throw BackendProtocolError.malformedMessage
        }
        terminalLeases.removeValue(forKey: key)
        if kind == .input {
        }
    }

    /// Sends one ordered input through the active presentation-bound lease.
    @discardableResult
    public func sendTerminalInput(
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        requestID: UUID,
        input: BackendTerminalControlInput
    ) async throws -> BackendTerminalOperationReceipt {
        try requireConnected()
        try requireMutationAccess(command: "terminal-input")
        let key = TerminalLeaseKey(surfaceID: surfaceID, kind: .input)
        await beginTerminalOperation(key)
        defer { endTerminalOperation(key) }
        try Task.checkCancellation()
        try requireConnected()
        try requireNonNil(requestID)
        var managed = try await refreshedTerminalLeaseIfNeeded(
            kind: .input,
            surfaceID: surfaceID,
            presentationID: presentationID,
            presentationGeneration: presentationGeneration
        )
        guard managed.nextSequence != UInt64.max else {
            throw BackendProtocolError.requestIDExhausted
        }
        let sequence = managed.nextSequence
        let group = inputGroupPlan(input: input)
        let receipt = try await client.sendTerminalInput(
            lease: managed.value,
            sequence: sequence,
            requestID: requestID,
            input: input,
            group: group
        )
        try validate(
            receipt,
            requestID: requestID,
            kind: .input,
            sequence: sequence,
            leaseGeneration: managed.value.leaseGeneration
        )
        managed.nextSequence = sequence + 1
        managed.localDeadline = leaseDeadline(ttlMilliseconds: managed.ttlMilliseconds)
        if receipt.status == .indeterminate {
            terminalLeases.removeValue(forKey: key)
            throw BackendTerminalControlError.indeterminate(
                requestID: requestID,
                diagnostic: receipt.diagnostic ?? "indeterminate PTY write"
            )
        }
        terminalLeases[key] = managed
        return receipt
    }

    /// Sends one independently ordered geometry mutation through the active lease.
    @discardableResult
    public func sendTerminalGeometry(
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        requestID: UUID,
        columns: UInt16,
        rows: UInt16
    ) async throws -> BackendTerminalOperationReceipt {
        try requireConnected()
        try requireMutationAccess(command: "terminal-geometry")
        let key = TerminalLeaseKey(surfaceID: surfaceID, kind: .geometry)
        await beginTerminalOperation(key)
        defer { endTerminalOperation(key) }
        try Task.checkCancellation()
        try requireConnected()
        try requireNonNil(requestID)
        var managed = try await refreshedTerminalLeaseIfNeeded(
            kind: .geometry,
            surfaceID: surfaceID,
            presentationID: presentationID,
            presentationGeneration: presentationGeneration
        )
        guard managed.nextSequence != UInt64.max else {
            throw BackendProtocolError.requestIDExhausted
        }
        let sequence = managed.nextSequence
        let receipt = try await client.sendTerminalGeometry(
            lease: managed.value,
            sequence: sequence,
            requestID: requestID,
            columns: columns,
            rows: rows
        )
        try validate(
            receipt,
            requestID: requestID,
            kind: .geometry,
            sequence: sequence,
            leaseGeneration: managed.value.leaseGeneration
        )
        managed.nextSequence = sequence + 1
        managed.localDeadline = leaseDeadline(ttlMilliseconds: managed.ttlMilliseconds)
        terminalLeases[key] = managed
        return receipt
    }

    /// Recovers one known idempotency receipt without requiring an active lease.
    public func terminalRequestStatus(
        surfaceID: SurfaceID,
        requestID: UUID
    ) async throws -> BackendTerminalOperationReceipt {
        try requireConnected()
        try requireLeasedProtocol()
        try requireNonNil(requestID)
        let receipt = try await client.terminalRequestStatus(
            surfaceID: surfaceID,
            requestID: requestID
        )
        guard receipt.requestID == requestID else {
            throw BackendProtocolError.malformedMessage
        }
        return receipt
    }

    /// Acknowledges a definitive receipt so the daemon can reclaim bounded storage.
    @discardableResult
    public func acknowledgeTerminalRequest(
        surfaceID: SurfaceID,
        requestID: UUID
    ) async throws -> Bool {
        try requireConnected()
        try requireLeasedProtocol()
        try requireNonNil(requestID)
        return try await client.acknowledgeTerminalRequest(
            surfaceID: surfaceID,
            requestID: requestID
        )
    }

    /// Creates an exactly identified terminal tab in one stable backend pane.
    public func newTerminalTab(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceID: SurfaceID,
        launch: BackendTerminalLaunch = BackendTerminalLaunch(),
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) async throws -> BackendSurfacePlacement {
        try requireCanonicalTopologyMutation(expectation, command: "canonical-new-tab")
        return try await client.canonicalNewTerminalTab(
            expectation: expectation,
            paneID: paneID,
            surfaceID: surfaceID,
            launch: launch,
            columns: columns,
            rows: rows
        )
    }

    /// Creates one daemon-owned browser in a new canonical workspace.
    public func newBrowserWorkspace(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        name: String? = nil,
        url: URL,
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) async throws -> BackendSurfacePlacement {
        try requireCanonicalTopologyMutation(expectation, command: "canonical-new-browser-workspace")
        return try await client.canonicalNewBrowserWorkspace(
            expectation: expectation,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            name: name,
            url: url,
            columns: columns,
            rows: rows
        )
    }

    /// Creates one daemon-owned browser tab in a stable canonical pane.
    public func newBrowserTab(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceID: SurfaceID,
        url: URL,
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) async throws -> BackendSurfacePlacement {
        try requireCanonicalTopologyMutation(expectation, command: "canonical-new-browser-tab")
        return try await client.canonicalNewBrowserTab(
            expectation: expectation,
            paneID: paneID,
            surfaceID: surfaceID,
            url: url,
            columns: columns,
            rows: rows
        )
    }

    /// Creates one daemon-owned browser in a new pane next to a stable pane.
    public func splitBrowserPane(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceID: SurfaceID,
        direction: BackendSplitDirection,
        initialRatio: Float,
        url: URL,
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) async throws -> BackendSurfacePlacement {
        try requireCanonicalTopologyMutation(expectation, command: "canonical-split-browser-pane")
        guard initialRatio.isFinite, initialRatio > 0, initialRatio < 1 else {
            throw BackendProtocolError.malformedMessage
        }
        return try await client.canonicalSplitBrowserPane(
            expectation: expectation,
            paneID: paneID,
            surfaceID: surfaceID,
            direction: direction,
            initialRatio: initialRatio,
            url: url,
            columns: columns,
            rows: rows
        )
    }

    public func splitPane(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceID: SurfaceID,
        direction: BackendSplitDirection,
        initialRatio: Float,
        launch: BackendTerminalLaunch = BackendTerminalLaunch(),
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) async throws -> BackendSurfacePlacement {
        try requireCanonicalTopologyMutation(expectation, command: "canonical-split-pane")
        guard initialRatio.isFinite, initialRatio > 0, initialRatio < 1 else {
            throw BackendProtocolError.malformedMessage
        }
        return try await client.canonicalSplitPane(
            expectation: expectation,
            paneID: paneID,
            surfaceID: surfaceID,
            direction: direction,
            initialRatio: initialRatio,
            launch: launch,
            columns: columns,
            rows: rows
        )
    }

    public func splitTab(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        paneID: PaneID,
        direction: BackendSplitDirection,
        initialRatio: Float
    ) async throws -> BackendSurfacePlacement {
        try requireCanonicalTopologyMutation(expectation, command: "canonical-split-tab")
        guard initialRatio.isFinite, initialRatio > 0, initialRatio < 1 else {
            throw BackendProtocolError.malformedMessage
        }
        return try await client.canonicalSplitTab(
            expectation: expectation,
            surfaceID: surfaceID,
            paneID: paneID,
            direction: direction,
            initialRatio: initialRatio
        )
    }

    public func closePane(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID
    ) async throws -> BackendTopologyMutationReceipt {
        try requireCanonicalTopologyMutation(expectation, command: "canonical-close-pane")
        return try await client.canonicalClosePane(expectation: expectation, paneID: paneID)
    }

    public func closeWorkspace(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID
    ) async throws -> BackendTopologyMutationReceipt {
        try requireCanonicalTopologyMutation(expectation, command: "canonical-close-workspace")
        return try await client.canonicalCloseWorkspace(
            expectation: expectation,
            workspaceID: workspaceID
        )
    }

    public func renameWorkspace(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID,
        name: String
    ) async throws -> BackendTopologyMutationReceipt {
        try requireCanonicalTopologyMutation(expectation, command: "canonical-rename-workspace")
        return try await client.canonicalRenameWorkspace(
            expectation: expectation,
            workspaceID: workspaceID,
            name: name
        )
    }

    public func renameSurface(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        name: String
    ) async throws -> BackendTopologyMutationReceipt {
        try requireCanonicalTopologyMutation(expectation, command: "canonical-rename-surface")
        return try await client.canonicalRenameSurface(
            expectation: expectation,
            surfaceID: surfaceID,
            name: name
        )
    }

    public func moveTab(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        paneID: PaneID,
        index: UInt64
    ) async throws -> BackendTopologyMutationReceipt {
        try requireCanonicalTopologyMutation(expectation, command: "canonical-move-tab")
        return try await client.canonicalMoveTab(
            expectation: expectation,
            surfaceID: surfaceID,
            paneID: paneID,
            index: index
        )
    }

    public func reorderTabs(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceIDs: [SurfaceID]
    ) async throws -> BackendTopologyMutationReceipt {
        try requireCanonicalTopologyMutation(expectation, command: "canonical-reorder-tabs")
        return try await client.canonicalReorderTabs(
            expectation: expectation,
            paneID: paneID,
            surfaceIDs: surfaceIDs
        )
    }

    public func reorderWorkspaces(
        expectation: BackendTopologyMutationExpectation,
        workspaceIDs: [WorkspaceID]
    ) async throws -> BackendTopologyMutationReceipt {
        try requireCanonicalTopologyMutation(expectation, command: "canonical-reorder-workspaces")
        return try await client.canonicalReorderWorkspaces(
            expectation: expectation,
            workspaceIDs: workspaceIDs
        )
    }

    public func moveTabToNewWorkspace(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        workspaceID: WorkspaceID,
        name: String? = nil,
        index: UInt64? = nil
    ) async throws -> BackendSurfacePlacement {
        try requireCanonicalTopologyMutation(expectation, command: "canonical-move-tab-to-new-workspace")
        return try await client.canonicalMoveTabToNewWorkspace(
            expectation: expectation,
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            name: name,
            index: index
        )
    }

    public func setSplitRatio(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        direction: BackendSplitDirection,
        ratio: Float
    ) async throws -> BackendTopologyMutationReceipt {
        try requireCanonicalTopologyMutation(expectation, command: "canonical-set-split-ratio")
        guard ratio.isFinite, ratio > 0, ratio < 1 else {
            throw BackendProtocolError.malformedMessage
        }
        return try await client.canonicalSetSplitRatio(
            expectation: expectation,
            paneID: paneID,
            direction: direction,
            ratio: ratio
        )
    }

    /// Registers a frontend presentation against stable canonical identities.
    public func openPresentation(
        view: BackendPresentationView,
        zoom: BackendPresentationZoom = BackendPresentationZoom(),
        scroll: BackendPresentationScroll = BackendPresentationScroll()
    ) async throws -> BackendPresentation {
        try requireConnected()
        try requireMutationAccess(command: "open-presentation")
        return try await client.openPresentation(view: view, zoom: zoom, scroll: scroll)
    }

    /// Removes one connection-owned presentation without closing its PTY.
    public func closePresentation(id: PresentationID) async throws {
        try requireConnected()
        try requireMutationAccess(command: "close-presentation")
        try await client.closePresentation(id: id)
    }

    public func sendTerminalKey(
        surface: UInt64,
        event: BackendTerminalKeyEvent
    ) async throws -> BackendTerminalKeyResponse {
        try requireConnected()
        try requireMutationAccess(command: "terminal-key")
        return try await client.sendTerminalKey(surface: surface, event: event)
    }

    public func sendTerminalNamedKey(surface: UInt64, key: String) async throws {
        try requireConnected()
        try requireMutationAccess(command: "send-key")
        try await client.sendTerminalNamedKey(surface: surface, key: key)
    }

    public func sendTerminalMouse(
        surface: UInt64,
        event: BackendTerminalMouseEvent
    ) async throws -> BackendTerminalMouseResponse {
        try requireConnected()
        try requireMutationAccess(command: "terminal-mouse")
        return try await client.sendTerminalMouse(surface: surface, event: event)
    }

    public func sendTerminalText(surface: UInt64, text: String, paste: Bool = false) async throws {
        try requireConnected()
        try requireMutationAccess(command: "send")
        try await client.sendTerminalText(surface: surface, text: text, paste: paste)
    }

    public func resizeTerminal(
        surface: UInt64,
        columns: UInt16,
        rows: UInt16
    ) async throws -> BackendSurfaceResizeResponse {
        try requireConnected()
        try requireMutationAccess(command: "resize-surface")
        return try await client.resizeTerminal(surface: surface, columns: columns, rows: rows)
    }

    public func scrollTerminal(surface: UInt64, rowDelta: Int64) async throws {
        try requireConnected()
        try requireMutationAccess(command: "scroll-surface")
        try await client.scrollTerminal(surface: surface, rowDelta: rowDelta)
    }

    public func terminalState(surfaceID: SurfaceID) async throws -> BackendTerminalStateResponse {
        try requireConnected()
        return try await client.terminalState(surfaceID: surfaceID)
    }

    public func terminalAccessibilitySnapshot(
        presentationID: PresentationID,
        expectedGeneration: UInt64,
        expectedContentSequence: UInt64
    ) async throws -> BackendTerminalAccessibilitySnapshot {
        try requireConnected()
        return try await client.terminalAccessibilitySnapshot(
            presentationID: presentationID,
            expectedGeneration: expectedGeneration,
            expectedContentSequence: expectedContentSequence
        )
    }

    public func activateTerminalAccessibilityLink(
        presentationID: PresentationID,
        expectedGeneration: UInt64,
        terminalRevision: UInt64,
        contentRevision: UInt64,
        viewportRevision: UInt64,
        linkID: String
    ) async throws -> BackendTerminalAccessibilityLinkActivation {
        try requireConnected()
        return try await client.activateTerminalAccessibilityLink(
            presentationID: presentationID,
            expectedGeneration: expectedGeneration,
            terminalRevision: terminalRevision,
            contentRevision: contentRevision,
            viewportRevision: viewportRevision,
            linkID: linkID
        )
    }

    public func terminalHyperlinkAtCell(
        presentationID: PresentationID,
        expectedGeneration: UInt64,
        expectedContentSequence: UInt64,
        column: UInt16,
        row: UInt16
    ) async throws -> BackendTerminalHyperlinkHit {
        try requireConnected()
        return try await client.terminalHyperlinkAtCell(
            presentationID: presentationID,
            expectedGeneration: expectedGeneration,
            expectedContentSequence: expectedContentSequence,
            column: column,
            row: row
        )
    }

    public func performTerminalBindingAction(
        surfaceID: SurfaceID,
        action: String,
        repeatCount: UInt32? = nil
    ) async throws -> BackendTerminalActionResponse {
        try requireConnected()
        try requireMutationAccess(command: "terminal-binding-action")
        return try await client.performTerminalBindingAction(
            surfaceID: surfaceID,
            action: action,
            repeatCount: repeatCount
        )
    }

    public func terminalSelection(
        surfaceID: SurfaceID,
        operation: BackendTerminalSelectionOperation
    ) async throws -> BackendTerminalSelectionResponse {
        try requireConnected()
        if operation != .read {
            try requireMutationAccess(command: "terminal-selection")
        }
        return try await client.terminalSelection(surfaceID: surfaceID, operation: operation)
    }

    public func terminalCopyMode(
        surfaceID: SurfaceID,
        operation: BackendTerminalCopyModeOperation,
        adjustment: BackendTerminalCopyModeAdjustment? = nil,
        count: UInt32? = nil
    ) async throws -> BackendTerminalActionResponse {
        try requireConnected()
        try requireMutationAccess(command: "terminal-copy-mode")
        return try await client.terminalCopyMode(
            surfaceID: surfaceID,
            operation: operation,
            adjustment: adjustment,
            count: count
        )
    }

    public func terminalSearch(
        surfaceID: SurfaceID,
        operation: BackendTerminalSearchOperation,
        query: String? = nil
    ) async throws -> BackendTerminalActionResponse {
        try requireConnected()
        try requireMutationAccess(command: "terminal-search")
        return try await client.terminalSearch(
            surfaceID: surfaceID,
            operation: operation,
            query: query
        )
    }

    public func terminalScroll(
        surfaceID: SurfaceID,
        operation: BackendTerminalScrollOperation,
        amount: Int64? = nil
    ) async throws -> BackendTerminalActionResponse {
        try requireConnected()
        try requireMutationAccess(command: "terminal-scroll")
        return try await client.terminalScroll(
            surfaceID: surfaceID,
            operation: operation,
            amount: amount
        )
    }

    public func readTerminalScreen(surface: UInt64) async throws -> BackendScreenText {
        try requireConnected()
        return try await client.readTerminalScreen(surface: surface)
    }

    public func terminalProcessInfo(surface: UInt64) async throws -> BackendProcessInfo {
        try requireConnected()
        return try await client.terminalProcessInfo(surface: surface)
    }

    public func closeTerminal(surface: UInt64) async throws {
        try requireConnected()
        try requireMutationAccess(command: "close-surface")
        try await client.closeTerminal(surface: surface)
    }

    private func negotiateTerminalControl(
        protocolVersion: UInt32,
        identify: BackendIdentifyResponse
    ) async throws {
        guard let terminalControl = BackendTerminalControlProtocol(rawValue: protocolVersion) else {
            throw BackendTerminalControlError.unsupportedProtocol(protocolVersion)
        }
        switch terminalControl {
        case .legacyV8:
            negotiatedTerminalControl = .legacyV8
            clientRegistration = nil
            topologyMutationLease = nil
        case .leasedV9:
            let missing = BackendHandshakePolicy.terminalControlV9Capabilities
                .subtracting(identify.capabilities)
            guard missing.isEmpty else {
                throw BackendProtocolError.missingCapabilities(missing)
            }
            let registration = try await client.registerClient(
                supportedRange: protocolVersion ... protocolVersion,
                identity: registrationIdentity
            )
            guard registration.protocolVersion == protocolVersion,
                  registration.clientUUID == registrationIdentity.clientUUID,
                  registration.processInstanceUUID == registrationIdentity.processInstanceUUID,
                  !isNil(registration.connectionID),
                  registration.clientKind == .swiftShell,
                  registration.role == .trustedFrontend,
                  let topologyMutationLease = registration.topologyMutationLease
            else {
                throw BackendTerminalControlError.registrationIdentityMismatch
            }
            negotiatedTerminalControl = .leasedV9
            clientRegistration = registration
            self.topologyMutationLease = topologyMutationLease
        }
    }

    private func acquireTerminalLeaseWithoutSerialization(
        kind: BackendTerminalLeaseKind,
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        ttlMilliseconds: UInt64
    ) async throws -> BackendTerminalLease {
        try requireLeasedProtocol()
        guard let registration = clientRegistration else {
            throw BackendTerminalControlError.protocolNotNegotiated
        }
        let effectiveTTL = min(
            max(ttlMilliseconds, 1),
            Self.maximumTerminalLeaseTTLMilliseconds
        )
        let response = try await client.acquireTerminalLease(
            kind: kind,
            surfaceID: surfaceID,
            presentationID: presentationID,
            presentationGeneration: presentationGeneration,
            ttlMilliseconds: effectiveTTL
        )
        guard response.kind == kind,
              response.surfaceID == surfaceID,
              response.presentationID == presentationID,
              response.presentationGeneration == presentationGeneration,
              !isNil(response.leaseID),
              response.leaseGeneration > 0,
              response.nextSequence > 0,
              (kind == .input) == (response.nextGlobalInputSequence != nil)
        else {
            throw BackendProtocolError.malformedMessage
        }

        let lease = BackendTerminalLease(
            connectionID: registration.connectionID,
            response: response
        )
        let key = TerminalLeaseKey(surfaceID: surfaceID, kind: kind)
        if let existing = terminalLeases[key],
           existing.value.presentationID == presentationID,
           existing.value.presentationGeneration == presentationGeneration {
            guard lease.leaseGeneration >= existing.value.leaseGeneration else {
                throw BackendProtocolError.malformedMessage
            }
            if lease.leaseGeneration == existing.value.leaseGeneration {
                guard lease.leaseID == existing.value.leaseID,
                      lease.nextSequence == existing.nextSequence,
                      lease.revocationSequence == existing.value.revocationSequence else {
                    throw BackendProtocolError.malformedMessage
                }
            }
        }
        terminalLeases[key] = ManagedTerminalLease(
            value: lease,
            nextSequence: lease.nextSequence,
            ttlMilliseconds: effectiveTTL,
            localDeadline: leaseDeadline(ttlMilliseconds: effectiveTTL)
        )
        return lease
    }

    private func refreshedTerminalLeaseIfNeeded(
        kind: BackendTerminalLeaseKind,
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64
    ) async throws -> ManagedTerminalLease {
        try requireLeasedProtocol()
        let key = TerminalLeaseKey(surfaceID: surfaceID, kind: kind)
        guard var managed = terminalLeases[key] else {
            throw BackendTerminalControlError.leaseUnavailable
        }
        try validateLeaseClaim(
            managed.value,
            surfaceID: surfaceID,
            presentationID: presentationID,
            presentationGeneration: presentationGeneration
        )
        let refreshMargin = min(
            Self.terminalLeaseRefreshMarginMilliseconds,
            managed.ttlMilliseconds
        )
        if managed.localDeadline <= clock.now.advanced(
            by: .milliseconds(Int64(refreshMargin))
        ) {
            let response = try await client.renewTerminalLease(
                managed.value,
                ttlMilliseconds: managed.ttlMilliseconds
            )
            guard response.kind == kind,
                  response.surfaceID == surfaceID,
                  response.presentationID == presentationID,
                  response.presentationGeneration == presentationGeneration,
                  response.leaseID == managed.value.leaseID,
                  response.leaseGeneration == managed.value.leaseGeneration,
                  response.revocationSequence == managed.value.revocationSequence,
                  response.nextSequence == managed.nextSequence else {
                throw BackendProtocolError.malformedMessage
            }
            managed.value = BackendTerminalLease(
                connectionID: managed.value.connectionID,
                response: response
            )
            managed.localDeadline = leaseDeadline(ttlMilliseconds: managed.ttlMilliseconds)
            terminalLeases[key] = managed
        }
        return managed
    }

    private func validateLeaseClaim(
        _ lease: BackendTerminalLease,
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64
    ) throws {
        guard let registration = clientRegistration,
              lease.connectionID == registration.connectionID else {
            throw BackendTerminalControlError.staleConnection
        }
        guard lease.surfaceID == surfaceID,
              lease.presentationID == presentationID,
              lease.presentationGeneration == presentationGeneration else {
            throw BackendTerminalControlError.staleLease
        }
    }

    private func validate(
        _ receipt: BackendTerminalOperationReceipt,
        requestID: UUID,
        kind: BackendTerminalOperationKind,
        sequence: UInt64,
        leaseGeneration: UInt64
    ) throws {
        guard receipt.requestID == requestID,
              receipt.kind == kind,
              receipt.sequence == sequence,
              receipt.leaseGeneration == leaseGeneration,
              receipt.replayed != nil,
              receipt.status != .unknown else {
            throw BackendProtocolError.malformedMessage
        }
        switch (kind, receipt.status) {
        case (.input, .applied):
            guard receipt.encodedBytes != nil,
                  receipt.orderedInputSequence != nil,
                  receipt.leaseRevoked == false else {
                throw BackendProtocolError.malformedMessage
            }
        case (.input, .indeterminate):
            guard receipt.diagnostic != nil,
                  receipt.orderedInputSequence != nil,
                  receipt.leaseRevoked == true else {
                throw BackendProtocolError.malformedMessage
            }
        case (.geometry, .applied):
            guard receipt.columns != nil,
                  receipt.rows != nil,
                  receipt.changed != nil,
                  receipt.orderedInputSequence == nil,
                  receipt.leaseRevoked == false else {
                throw BackendProtocolError.malformedMessage
            }
        case (.geometry, .indeterminate), (_, .unknown):
            throw BackendProtocolError.malformedMessage
        }
    }

    private func requireLeasedProtocol() throws {
        guard let negotiatedTerminalControl else {
            throw BackendTerminalControlError.protocolNotNegotiated
        }
        guard negotiatedTerminalControl == .leasedV9 else {
            throw BackendTerminalControlError.unsupportedProtocol(
                negotiatedTerminalControl.rawValue
            )
        }
    }

    private func requireNonNil(_ identifier: UUID) throws {
        guard !isNil(identifier) else { throw BackendProtocolError.malformedMessage }
    }

    private func isNil(_ identifier: UUID) -> Bool {
        identifier == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }

    private func leaseDeadline(ttlMilliseconds: UInt64) -> ContinuousClock.Instant {
        clock.now.advanced(by: .milliseconds(Int64(ttlMilliseconds)))
    }

    private func inputGroupPlan(
        input: BackendTerminalControlInput
    ) -> BackendTerminalInputGroup? {
        let single = {
            BackendTerminalInputGroup(id: UUID(), index: 0, end: true)
        }
        switch input {
        case .text(_, let paste), .bytes(_, let paste):
            return paste ? single() : nil
        case .namedKey:
            return single()
        case .key:
            // Physical key events are individually atomic. Keeping a group
            // open until key-up rejects normal rollover (A-down, B-down) and
            // keyboard input during a mouse drag.
            return single()
        case .mouse(let event):
            return event.action == .motion && !event.anyButtonPressed ? nil : single()
        }
    }

    private func beginTerminalOperation(_ key: TerminalLeaseKey) async {
        if terminalOperationsInFlight.insert(key).inserted { return }
        await withCheckedContinuation { continuation in
            terminalOperationWaiters[key, default: []].append(continuation)
        }
    }

    private func endTerminalOperation(_ key: TerminalLeaseKey) {
        guard var waiters = terminalOperationWaiters[key], !waiters.isEmpty else {
            terminalOperationsInFlight.remove(key)
            terminalOperationWaiters.removeValue(forKey: key)
            return
        }
        let next = waiters.removeFirst()
        if waiters.isEmpty {
            terminalOperationWaiters.removeValue(forKey: key)
        } else {
            terminalOperationWaiters[key] = waiters
        }
        next.resume()
    }

    private func resetTerminalControlState() {
        negotiatedTerminalControl = nil
        clientRegistration = nil
        topologyMutationLease = nil
        terminalLeases.removeAll()
    }

    private func validateIdentity(_ identify: BackendIdentifyResponse) throws {
        guard identify.session == expectation.session else {
            throw BackendCanonicalSessionError.unexpectedSession(
                expected: expectation.session,
                actual: identify.session
            )
        }
        if let authority = expectation.authority, identify.authority != authority {
            throw BackendCanonicalSessionError.unexpectedAuthority(
                expected: authority,
                actual: identify.authority
            )
        }
        if let processID = expectation.processID, identify.processID != processID {
            throw BackendCanonicalSessionError.unexpectedProcessID(
                expected: processID,
                actual: identify.processID
            )
        }
    }

    private func startEventTask(
        _ stream: AsyncThrowingStream<BackendServerEvent, any Error>,
        applyCanonicalEvents: Bool
    ) {
        eventTask = Task { [weak self] in
            do {
                for try await event in stream {
                    if applyCanonicalEvents {
                        await self?.receive(event)
                    }
                }
                await self?.finish(
                    BackendCanonicalSessionError.topologyStreamFailed("connection closed")
                )
            } catch is CancellationError {
                // Explicit close owns the terminal state transition.
            } catch {
                await self?.finish(
                    BackendCanonicalSessionError.topologyStreamFailed(String(describing: error))
                )
            }
        }
    }

    private func receive(_ event: BackendServerEvent) async {
        guard connected else { return }
        if event.name == "terminal-activity" {
            do {
                let fact = try event.terminalActivityFact()
                if try activityProjection.apply(fact) {
                    publish(.terminalActivity(fact))
                }
            } catch {
                await finish(.topologyStreamFailed(String(describing: error)))
            }
            return
        }
        if event.name == "terminal-activity-receipt" {
            do {
                let receipt = try event.terminalActivityReceipt()
                if try activityProjection.apply(receipt) {
                    publish(.terminalActivityReceipt(receipt))
                }
            } catch {
                await finish(.topologyStreamFailed(String(describing: error)))
            }
            return
        }
        if event.name == "renderer-worker-changed" {
            do {
                publish(.rendererWorkerChanged(try event.rendererWorkerChanged()))
            } catch {
                await finish(.topologyStreamFailed(String(describing: error)))
            }
            return
        }
        if event.name == "renderer-presentation-ready" {
            do {
                publish(.rendererPresentationReady(try event.rendererPresentationReady()))
            } catch {
                await finish(.topologyStreamFailed(String(describing: error)))
            }
            return
        }
        guard event.name == "topology-delta" || event.name == "topology-resnapshot-required" else {
            return
        }
        do {
            switch try event.topologyStreamEvent() {
            case .delta(let delta):
                try projection.apply(delta)
                publish(.delta(delta))
            case .resnapshotRequired(let required):
                try projection.requireResnapshot(required)
            }
        } catch let error as BackendCanonicalSessionError {
            await finish(error)
        } catch let error as TopologyProjectionError {
            await finish(.topologyStreamFailed(String(describing: error)))
        } catch {
            await finish(.topologyStreamFailed(String(describing: error)))
        }
    }

    private func requireConnected() throws {
        guard connected else { throw BackendCanonicalSessionError.notConnected }
    }

    private func requireMutationAccess(command: String) throws {
        guard let negotiatedCompatibility else {
            throw BackendProtocolError.malformedMessage
        }
        guard case .readOnly(let diagnostic) = negotiatedCompatibility else { return }
        throw BackendProtocolError.mutationUnavailableInReadOnlyMode(
            command: command,
            compatibility: diagnostic
        )
    }

    private func requireCanonicalTopologyMutation(command: String) throws {
        try requireConnected()
        try requireMutationAccess(command: command)
        try requireCapability(Self.canonicalTopologyMutationsCapability)
    }

    private func requireCanonicalTopologyMutation(
        _ expectation: BackendTopologyMutationExpectation,
        command: String
    ) throws {
        try requireCanonicalTopologyMutation(command: command)
        guard expectation.authority == projection.authority,
              expectation.revision == projection.revision
        else {
            throw BackendProtocolError.invalidTopology(
                "canonical topology mutation expectation is not the current installed snapshot"
            )
        }
        guard let registration = clientRegistration,
              let topologyMutationLease,
              topologyMutationLease.connectionID == registration.connectionID,
              expectation.topologyLease == topologyMutationLease
        else {
            throw BackendTerminalControlError.staleConnection
        }
    }

    private func requireCapability(_ capability: String) throws {
        guard advertisedCapabilities.contains(capability) else {
            throw BackendProtocolError.missingCapabilities([capability])
        }
    }

    private func finish(_ error: BackendCanonicalSessionError) async {
        guard connected || terminalError == nil else { return }
        connected = false
        projection.invalidate()
        identifiedBackend = nil
        negotiatedCompatibility = nil
        advertisedCapabilities.removeAll()
        activityProjection.invalidate()
        resetTerminalControlState()
        terminalError = error
        publish(.disconnected(error))
        await client.close()
    }

    private func publish(_ event: BackendCanonicalSessionEvent) {
        var retired: [UUID] = []
        for (identifier, continuation) in continuations {
            switch continuation.yield(event) {
            case .enqueued:
                break
            case .dropped, .terminated:
                continuation.finish()
                retired.append(identifier)
            @unknown default:
                continuation.finish()
                retired.append(identifier)
            }
        }
        for identifier in retired {
            continuations.removeValue(forKey: identifier)
        }
    }

    private func finishContinuations() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }
}

private extension CanonicalTopology {
    var liveSurfaceIDs: Set<SurfaceID> {
        Set(workspaces.flatMap { workspace in
            workspace.screens.flatMap { screen in
                screen.panes.flatMap { pane in pane.tabs.map(\.uuid) }
            }
        })
    }

    func surface(handle: UInt64) -> CanonicalSurface? {
        for workspace in workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    if let surface = pane.tabs.first(where: { $0.id == handle }) {
                        return surface
                    }
                }
            }
        }
        return nil
    }
}
