public import Foundation

/// App/window-scoped coordinator that binds one nested-provider connection to one
/// host cmux terminal surface.
///
/// ## Ownership
///
/// Herdr descendants remain **virtual** under the host surface. This coordinator
/// never mirrors provider panes into Bonsplit / Ghostty PTYs and never invokes
/// `server.stop` or child closes when the host surface closes or moves.
///
/// ## Authorization
///
/// ``attach(hostWorkspaceID:hostStableSurfaceID:providerKind:socketPath:authorization:)``
/// requires ``NestedAttachmentAuthorization``. Environment/OSC proposals may be
/// recorded via ``recordProposal(_:)`` but do not authorize attachment alone.
///
/// ## Threading
///
/// The coordinator is an actor. Provider I/O runs in tasks owned here; callers
/// should not perform socket work on the main actor while holding UI state.
public actor NestedTopologyAttachmentCoordinator {
    private var attachments: [UUID: NestedAttachmentRecord]
    private var proposals: [UUID: NestedAttachmentProposal]
    private var eventTasks: [UUID: Task<Void, Never>]
    private var generationTokens: [UUID: UUID]
    private var liveEnvironmentSurfaceIDs: Set<UUID>
    /// Live provider clients retained for capability-gated mutations (PR5).
    private var liveClients: [UUID: any NestedTopologyProviderClient]
    /// Persistent topology reducers keyed by host surface (one per attachment generation).
    private var topologyReducers: [UUID: NestedTopologyReducer]

    private let validator: any NestedEndpointValidating
    private let clientFactory: any NestedTopologyProviderClientFactory
    private let handoff: NestedPluginWriterHandoff
    private let limits: NestedAttachmentLimits
    private let clientConfigurationDefaults: ClientConfigurationDefaults
    private let telemetrySink: (@Sendable (NestedAttachmentTelemetryEvent) -> Void)?
    private let environmentMirrorSink: (@Sendable (String) -> Void)?
    private let persistenceIntents = NestedPersistenceIntentBox()

    /// Defaults applied when constructing Herdr client configurations.
    public struct ClientConfigurationDefaults: Hashable, Sendable {
        public var connectTimeout: Duration
        public var requestTimeout: Duration
        public var topologyLimits: NestedTopologyLimits

        public init(
            connectTimeout: Duration = .seconds(5),
            requestTimeout: Duration = .seconds(5),
            topologyLimits: NestedTopologyLimits = .default
        ) {
            self.connectTimeout = connectTimeout
            self.requestTimeout = requestTimeout
            self.topologyLimits = topologyLimits
        }
    }

    /// Creates an attachment coordinator.
    ///
    /// - Parameters:
    ///   - validator: Endpoint security validator.
    ///   - clientFactory: Provider client factory.
    ///   - handoff: Plugin single-writer handoff manager.
    ///   - limits: Per-coordinator attachment bounds.
    ///   - clientConfigurationDefaults: Timeouts/limits for created clients.
    ///   - telemetrySink: Optional redacted telemetry sink (no socket paths).
    ///   - environmentMirrorSink: Optional sink for ``NestedPluginWriterHandoff/environmentKey`` updates.
    public init(
        validator: any NestedEndpointValidating = NestedUnixSocketEndpointValidator(),
        clientFactory: any NestedTopologyProviderClientFactory = HerdrNestedTopologyClientFactory(),
        handoff: NestedPluginWriterHandoff,
        limits: NestedAttachmentLimits = .default,
        clientConfigurationDefaults: ClientConfigurationDefaults = ClientConfigurationDefaults(),
        telemetrySink: (@Sendable (NestedAttachmentTelemetryEvent) -> Void)? = nil,
        environmentMirrorSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.attachments = [:]
        self.proposals = [:]
        self.eventTasks = [:]
        self.generationTokens = [:]
        self.liveEnvironmentSurfaceIDs = []
        self.liveClients = [:]
        self.topologyReducers = [:]
        self.validator = validator
        self.clientFactory = clientFactory
        self.handoff = handoff
        self.limits = limits
        self.clientConfigurationDefaults = clientConfigurationDefaults
        self.telemetrySink = telemetrySink
        self.environmentMirrorSink = environmentMirrorSink
    }

    // MARK: - Queries

    /// Returns the attachment for a host stable surface, if any.
    public func attachment(for hostStableSurfaceID: UUID) -> NestedAttachmentRecord? {
        attachments[hostStableSurfaceID]
    }

    /// Fresh persistence intent published on every attach/detach/restore mutation.
    ///
    /// Safe to read from session-snapshot capture without awaiting the actor.
    public nonisolated func persistenceIntent(
        for hostStableSurfaceID: UUID
    ) -> NestedAttachmentIntentDescriptor? {
        persistenceIntents.intent(for: hostStableSurfaceID)
    }

    /// All retained attachments in deterministic host-surface order.
    public func allAttachments() -> [NestedAttachmentRecord] {
        attachments.values.sorted {
            $0.hostStableSurfaceID.uuidString < $1.hostStableSurfaceID.uuidString
        }
    }

    /// Pending non-authoritative proposal for a host surface, if any.
    public func pendingProposal(for hostStableSurfaceID: UUID) -> NestedAttachmentProposal? {
        proposals[hostStableSurfaceID]
    }

    /// Whether the plugin should suppress writers for the host surface.
    public func shouldSuppressPluginWriters(for hostStableSurfaceID: UUID) -> Bool {
        if let record = attachments[hostStableSurfaceID], record.suppressesPluginWriters {
            return true
        }
        return handoff.shouldSuppressPluginWriters(hostStableSurfaceID: hostStableSurfaceID)
    }

    // MARK: - Proposals (non-authoritative)

    /// Records an environment/OSC attachment proposal without authorizing connect.
    public func recordProposal(_ proposal: NestedAttachmentProposal) {
        proposals[proposal.hostStableSurfaceID] = proposal
        emit(
            NestedAttachmentTelemetryEvent(
                name: "proposal_recorded",
                state: .disconnected,
                providerKind: proposal.providerKind,
                hostStableSurfaceID: proposal.hostStableSurfaceID
            )
        )
    }

    /// Clears a pending proposal without affecting any live attachment.
    public func clearProposal(for hostStableSurfaceID: UUID) {
        proposals.removeValue(forKey: hostStableSurfaceID)
    }

    // MARK: - Attach / detach

    /// Explicitly attaches a nested provider to a host surface.
    ///
    /// - Parameters:
    ///   - hostWorkspaceID: Current host workspace ID.
    ///   - hostStableSurfaceID: Stable surface identity (attachment key).
    ///   - providerKind: Provider kind (currently `.herdr` only).
    ///   - socketPath: Candidate local Unix socket path.
    ///   - authorization: Explicit opt-in authority. `nil` / missing opt-in is rejected;
    ///     a recorded proposal alone is never sufficient.
    /// - Returns: The live (or terminal failure) attachment record.
    @discardableResult
    public func attach(
        hostWorkspaceID: String,
        hostStableSurfaceID: UUID,
        providerKind: NestedProviderKind,
        socketPath: String,
        authorization: NestedAttachmentAuthorization?
    ) async throws -> NestedAttachmentRecord {
        guard let authorization, authorization.isExplicitOptIn else {
            throw NestedAttachmentError.optInRequired
        }
        try validateAuthorizationRequestID(authorization)

        let sanitizedWorkspaceID = NestedDisplayStringSanitizer.sanitize(
            hostWorkspaceID,
            maxUTF8ByteCount: limits.maxHostWorkspaceIDUTF8ByteCount
        )
        guard !sanitizedWorkspaceID.isEmpty else {
            throw NestedAttachmentError.oversizedField("host_workspace_id")
        }

        if let existing = attachments[hostStableSurfaceID] {
            switch existing.state {
            case .connecting, .live, .stale:
                throw NestedAttachmentError.duplicateAttachment(
                    hostStableSurfaceID: hostStableSurfaceID
                )
            case .disconnected, .incompatible, .rejected:
                await detach(
                    hostStableSurfaceID: hostStableSurfaceID,
                    reason: .cancelled,
                    emitTelemetry: false
                )
            }
        }

        let activeAttachmentCount = attachments.values.reduce(into: 0) { count, record in
            switch record.state {
            case .connecting, .live, .stale:
                count += 1
            case .disconnected, .incompatible, .rejected:
                break
            }
        }
        if activeAttachmentCount >= limits.maxConcurrentAttachments {
            throw NestedAttachmentError.attachmentLimitExceeded(
                limit: limits.maxConcurrentAttachments
            )
        }

        let endpoint: NestedAttachmentEndpoint
        do {
            endpoint = try validator.validatePreConnect(path: socketPath)
        } catch let error as NestedEndpointSecurityError {
            let record = NestedAttachmentRecord(
                hostWorkspaceID: sanitizedWorkspaceID,
                hostStableSurfaceID: hostStableSurfaceID,
                providerKind: providerKind,
                state: .rejected,
                lastErrorClass: NestedAttachmentError.endpointRejected(error).telemetryErrorClass
            )
            attachments[hostStableSurfaceID] = record
            emit(
                NestedAttachmentTelemetryEvent(
                    name: "attach_rejected",
                    state: .rejected,
                    providerKind: providerKind,
                    errorClass: record.lastErrorClass,
                    hostStableSurfaceID: hostStableSurfaceID,
                    attachmentID: record.attachmentID
                )
            )
            throw NestedAttachmentError.endpointRejected(error)
        }

        let attachmentID = UUID()
        let generation = UUID()
        generationTokens[hostStableSurfaceID] = generation

        var record = NestedAttachmentRecord(
            attachmentID: attachmentID,
            hostWorkspaceID: sanitizedWorkspaceID,
            hostStableSurfaceID: hostStableSurfaceID,
            providerKind: providerKind,
            endpoint: endpoint,
            state: .connecting
        )
        attachments[hostStableSurfaceID] = record
        emit(
            NestedAttachmentTelemetryEvent(
                name: "attach_started",
                state: .connecting,
                providerKind: providerKind,
                hostStableSurfaceID: hostStableSurfaceID,
                attachmentID: attachmentID
            )
        )

        do {
            try Task.checkCancellation()
            guard generationTokens[hostStableSurfaceID] == generation else {
                throw NestedAttachmentError.cancelled
            }

            switch providerKind {
            case .herdr:
                let configuration = HerdrNestedTopologyClientConfiguration(
                    socketPath: endpoint.canonicalPath,
                    attachmentID: attachmentID,
                    hostStableSurfaceID: hostStableSurfaceID,
                    connectTimeout: clientConfigurationDefaults.connectTimeout,
                    requestTimeout: clientConfigurationDefaults.requestTimeout,
                    topologyLimits: clientConfigurationDefaults.topologyLimits
                )
                let client = clientFactory.makeHerdrClient(configuration: configuration)
                let handshake = try await client.handshake()

                guard generationTokens[hostStableSurfaceID] == generation else {
                    throw NestedAttachmentError.cancelled
                }

                try validator.revalidateIdentity(
                    path: endpoint.canonicalPath,
                    expected: endpoint.fileIdentity
                )

                let snapshot = try await client.snapshot()
                guard generationTokens[hostStableSurfaceID] == generation else {
                    throw NestedAttachmentError.cancelled
                }

                try handoff.acquire(
                    hostStableSurfaceID: hostStableSurfaceID,
                    attachmentID: attachmentID
                )
                liveEnvironmentSurfaceIDs.insert(hostStableSurfaceID)
                publishEnvironmentMirror()

                record.providerInstanceID = handshake.providerInstanceID
                record.providerInstanceIdentityProofAvailable = handshake.instanceIdentityIsDurable
                record.capabilities = handshake.capabilities
                record.latestSnapshot = snapshot
                record.state = .live
                record.pluginWriterHandoffActive = true
                record.lastErrorClass = nil
                record.pendingRestoreIntent = nil
                attachments[hostStableSurfaceID] = record
                liveClients[hostStableSurfaceID] = client

                startEventObservation(
                    hostStableSurfaceID: hostStableSurfaceID,
                    generation: generation,
                    client: client
                )

                emit(
                    NestedAttachmentTelemetryEvent(
                        name: "attach_live",
                        state: .live,
                        providerKind: providerKind,
                        hostStableSurfaceID: hostStableSurfaceID,
                        attachmentID: attachmentID
                    )
                )
                return record
            }
        } catch is CancellationError {
            await failAttachment(
                hostStableSurfaceID: hostStableSurfaceID,
                generation: generation,
                state: .disconnected,
                error: .cancelled,
                remove: true
            )
            throw NestedAttachmentError.cancelled
        } catch let error as NestedAttachmentError {
            let state: NestedConnectionState
            switch error {
            case .cancelled:
                state = .disconnected
            case .endpointRejected:
                state = .rejected
            case .incompatibleProvider:
                state = .incompatible
            default:
                state = .disconnected
            }
            await failAttachment(
                hostStableSurfaceID: hostStableSurfaceID,
                generation: generation,
                state: state,
                error: error,
                remove: error == .cancelled
            )
            throw error
        } catch let error as NestedEndpointSecurityError {
            let wrapped = NestedAttachmentError.endpointRejected(error)
            await failAttachment(
                hostStableSurfaceID: hostStableSurfaceID,
                generation: generation,
                state: .rejected,
                error: wrapped,
                remove: false
            )
            throw wrapped
        } catch let error as NestedTopologyProviderError {
            if case .unsupportedProtocol = error {
                let wrapped = NestedAttachmentError.incompatibleProvider(
                    detail: error.localizedDescription
                )
                await failAttachment(
                    hostStableSurfaceID: hostStableSurfaceID,
                    generation: generation,
                    state: .incompatible,
                    error: wrapped,
                    remove: false
                )
                throw wrapped
            }
            let wrapped = NestedAttachmentError.providerFailed(
                detail: error.localizedDescription
            )
            await failAttachment(
                hostStableSurfaceID: hostStableSurfaceID,
                generation: generation,
                state: .disconnected,
                error: wrapped,
                remove: false
            )
            throw wrapped
        } catch {
            let wrapped = NestedAttachmentError.providerFailed(
                detail: String(describing: type(of: error))
            )
            await failAttachment(
                hostStableSurfaceID: hostStableSurfaceID,
                generation: generation,
                state: .disconnected,
                error: wrapped,
                remove: false
            )
            throw wrapped
        }
    }

    /// Restores attachment intent from a session snapshot (PR 6).
    ///
    /// Re-runs security and compatibility checks, compares provider identity, and
    /// fetches a **fresh** snapshot. Never rehydrates nested nodes, output,
    /// credentials, or association records from the persisted intent.
    ///
    /// When identity proof is unavailable or mismatched — or the reattach policy
    /// requires confirmation — the attachment is left ``disconnected`` with a
    /// pending intent so the UI / control socket can confirm before connecting.
    @discardableResult
    public func restoreFromIntent(
        hostWorkspaceID: String,
        hostStableSurfaceID: UUID,
        intent: NestedAttachmentIntentDescriptor
    ) async -> NestedAttachmentRecord {
        let sanitizedWorkspaceID = NestedDisplayStringSanitizer.sanitize(
            hostWorkspaceID,
            maxUTF8ByteCount: limits.maxHostWorkspaceIDUTF8ByteCount
        )
        let workspaceID = sanitizedWorkspaceID
        guard !workspaceID.isEmpty else {
            return await leaveRestoreDisconnected(
                hostStableSurfaceID: hostStableSurfaceID,
                intent: intent,
                error: .oversizedField("host_workspace_id")
            )
        }

        if let existing = attachments[hostStableSurfaceID] {
            switch existing.state {
            case .connecting, .live, .stale:
                emit(
                    NestedAttachmentTelemetryEvent(
                        name: "restore_skipped_live",
                        state: existing.state,
                        providerKind: existing.providerKind,
                        hostStableSurfaceID: hostStableSurfaceID,
                        attachmentID: existing.attachmentID
                    )
                )
                return existing
            case .disconnected, .incompatible, .rejected:
                await detach(
                    hostStableSurfaceID: hostStableSurfaceID,
                    reason: .cancelled,
                    emitTelemetry: false
                )
            }
        }

        var pending = NestedAttachmentRecord(
            hostWorkspaceID: workspaceID,
            hostStableSurfaceID: hostStableSurfaceID,
            providerKind: intent.providerKind,
            state: .disconnected,
            lastErrorClass: NestedAttachmentError.restoreRequiresConfirmation(
                reason: .pending
            ).telemetryErrorClass,
            pendingRestoreIntent: intent
        )
        attachments[hostStableSurfaceID] = pending
        emit(
            NestedAttachmentTelemetryEvent(
                name: "restore_started",
                state: .disconnected,
                providerKind: intent.providerKind,
                hostStableSurfaceID: hostStableSurfaceID,
                attachmentID: pending.attachmentID
            )
        )

        guard intent.allowsUnattendedAutoReattach,
              let locator = intent.endpointLocator,
              let expectedInstanceID = intent.lastVerifiedProviderInstanceID
        else {
            let reason: NestedRestoreConfirmationReason
            if intent.reattachPolicy != .autoIfProviderInstanceMatches {
                reason = .policyRequiresConfirmation
            } else if !intent.providerInstanceIdentityProofAvailable
                || intent.lastVerifiedProviderInstanceID == nil
                || intent.lastVerifiedFileIdentity == nil
            {
                reason = .identityProofUnavailable
            } else {
                reason = .endpointMissing
            }
            return await leaveRestoreDisconnected(
                hostStableSurfaceID: hostStableSurfaceID,
                intent: intent,
                error: .restoreRequiresConfirmation(reason: reason)
            )
        }

        let endpoint: NestedAttachmentEndpoint
        do {
            endpoint = try validator.validatePreConnect(path: locator.socketPath)
        } catch let error as NestedEndpointSecurityError {
            return await leaveRestoreDisconnected(
                hostStableSurfaceID: hostStableSurfaceID,
                intent: intent,
                error: .endpointRejected(error)
            )
        } catch {
            return await leaveRestoreDisconnected(
                hostStableSurfaceID: hostStableSurfaceID,
                intent: intent,
                error: .restoreProviderUnavailable
            )
        }

        if let expectedIdentity = intent.lastVerifiedFileIdentity,
           expectedIdentity != endpoint.fileIdentity
        {
            return await leaveRestoreDisconnected(
                hostStableSurfaceID: hostStableSurfaceID,
                intent: intent,
                error: .restoreSocketIdentityChanged
            )
        }

        let generation = UUID()
        generationTokens[hostStableSurfaceID] = generation
        pending.state = .connecting
        pending.endpoint = endpoint
        pending.lastErrorClass = nil
        attachments[hostStableSurfaceID] = pending

        do {
            try Task.checkCancellation()
            guard generationTokens[hostStableSurfaceID] == generation else {
                throw NestedAttachmentError.cancelled
            }

            switch intent.providerKind {
            case .herdr:
                let configuration = HerdrNestedTopologyClientConfiguration(
                    socketPath: endpoint.canonicalPath,
                    attachmentID: pending.attachmentID,
                    hostStableSurfaceID: hostStableSurfaceID,
                    connectTimeout: clientConfigurationDefaults.connectTimeout,
                    requestTimeout: clientConfigurationDefaults.requestTimeout,
                    topologyLimits: clientConfigurationDefaults.topologyLimits
                )
                // Fresh client → empty in-memory association store (never rehydrated
                // from session snapshots / plugin association state files).
                let client = clientFactory.makeHerdrClient(configuration: configuration)
                let handshake = try await client.handshake()

                guard generationTokens[hostStableSurfaceID] == generation else {
                    throw NestedAttachmentError.cancelled
                }

                try validator.revalidateIdentity(
                    path: endpoint.canonicalPath,
                    expected: endpoint.fileIdentity
                )

                guard handshake.instanceIdentityIsDurable else {
                    throw NestedAttachmentError.restoreRequiresConfirmation(
                        reason: .identityProofUnavailable
                    )
                }
                guard handshake.providerInstanceID == expectedInstanceID else {
                    throw NestedAttachmentError.restoreRequiresConfirmation(
                        reason: .providerInstanceMismatch
                    )
                }

                let snapshot = try await client.snapshot()
                guard generationTokens[hostStableSurfaceID] == generation else {
                    throw NestedAttachmentError.cancelled
                }

                try handoff.acquire(
                    hostStableSurfaceID: hostStableSurfaceID,
                    attachmentID: pending.attachmentID
                )
                liveEnvironmentSurfaceIDs.insert(hostStableSurfaceID)
                publishEnvironmentMirror()

                pending.providerInstanceID = handshake.providerInstanceID
                pending.providerInstanceIdentityProofAvailable = true
                pending.capabilities = handshake.capabilities
                pending.latestSnapshot = snapshot
                pending.state = .live
                pending.pluginWriterHandoffActive = true
                pending.lastErrorClass = nil
                pending.pendingRestoreIntent = nil
                attachments[hostStableSurfaceID] = pending
                liveClients[hostStableSurfaceID] = client

                startEventObservation(
                    hostStableSurfaceID: hostStableSurfaceID,
                    generation: generation,
                    client: client
                )

                emit(
                    NestedAttachmentTelemetryEvent(
                        name: "restore_live",
                        state: .live,
                        providerKind: intent.providerKind,
                        hostStableSurfaceID: hostStableSurfaceID,
                        attachmentID: pending.attachmentID
                    )
                )
                return pending
            }
        } catch is CancellationError {
            await failAttachment(
                hostStableSurfaceID: hostStableSurfaceID,
                generation: generation,
                state: .disconnected,
                error: .cancelled,
                remove: true
            )
            return NestedAttachmentRecord(
                hostWorkspaceID: workspaceID,
                hostStableSurfaceID: hostStableSurfaceID,
                providerKind: intent.providerKind,
                state: .disconnected,
                lastErrorClass: NestedAttachmentError.cancelled.telemetryErrorClass
            )
        } catch let error as NestedAttachmentError {
            if error == .cancelled {
                await failAttachment(
                    hostStableSurfaceID: hostStableSurfaceID,
                    generation: generation,
                    state: .disconnected,
                    error: .cancelled,
                    remove: true
                )
                return NestedAttachmentRecord(
                    hostWorkspaceID: workspaceID,
                    hostStableSurfaceID: hostStableSurfaceID,
                    providerKind: intent.providerKind,
                    state: .disconnected,
                    lastErrorClass: NestedAttachmentError.cancelled.telemetryErrorClass
                )
            }
            return await leaveRestoreDisconnected(
                hostStableSurfaceID: hostStableSurfaceID,
                intent: intent,
                error: error,
                generation: generation
            )
        } catch let error as NestedEndpointSecurityError {
            return await leaveRestoreDisconnected(
                hostStableSurfaceID: hostStableSurfaceID,
                intent: intent,
                error: .endpointRejected(error),
                generation: generation
            )
        } catch let error as NestedTopologyProviderError {
            if case .unsupportedProtocol = error {
                return await leaveRestoreDisconnected(
                    hostStableSurfaceID: hostStableSurfaceID,
                    intent: intent,
                    error: .incompatibleProvider(detail: error.localizedDescription),
                    generation: generation
                )
            }
            return await leaveRestoreDisconnected(
                hostStableSurfaceID: hostStableSurfaceID,
                intent: intent,
                error: .restoreProviderUnavailable,
                generation: generation
            )
        } catch {
            return await leaveRestoreDisconnected(
                hostStableSurfaceID: hostStableSurfaceID,
                intent: intent,
                error: .restoreProviderUnavailable,
                generation: generation
            )
        }
    }

    /// Confirms a previously restored disconnected intent (user / control-socket).
    @discardableResult
    public func confirmPendingRestore(
        hostStableSurfaceID: UUID,
        authorization: NestedAttachmentAuthorization?
    ) async throws -> NestedAttachmentRecord {
        guard let authorization, authorization.isExplicitOptIn else {
            throw NestedAttachmentError.optInRequired
        }
        guard let record = attachments[hostStableSurfaceID],
              let intent = record.pendingRestoreIntent,
              let locator = intent.endpointLocator
        else {
            throw NestedAttachmentError.attachmentNotFound(
                hostStableSurfaceID: hostStableSurfaceID
            )
        }
        return try await attach(
            hostWorkspaceID: record.hostWorkspaceID,
            hostStableSurfaceID: hostStableSurfaceID,
            providerKind: intent.providerKind,
            socketPath: locator.socketPath,
            authorization: authorization
        )
    }

    /// Detaches a host surface without stopping the provider or closing children.
    public func detach(
        hostStableSurfaceID: UUID,
        reason: NestedDetachReason
    ) async {
        await detach(
            hostStableSurfaceID: hostStableSurfaceID,
            reason: reason,
            emitTelemetry: true
        )
    }

    /// Host surface moved to another workspace — attachment is preserved.
    public func noteHostSurfaceMoved(
        hostStableSurfaceID: UUID,
        toWorkspaceID: String
    ) {
        guard var record = attachments[hostStableSurfaceID] else { return }
        let sanitized = NestedDisplayStringSanitizer.sanitize(
            toWorkspaceID,
            maxUTF8ByteCount: limits.maxHostWorkspaceIDUTF8ByteCount
        )
        guard !sanitized.isEmpty else { return }
        record.hostWorkspaceID = sanitized
        attachments[hostStableSurfaceID] = record
        emit(
            NestedAttachmentTelemetryEvent(
                name: "host_moved",
                state: record.state,
                providerKind: record.providerKind,
                hostStableSurfaceID: hostStableSurfaceID,
                attachmentID: record.attachmentID
            )
        )
    }

    /// Host surface closed — detach observer only (no `server.stop` / child closes).
    public func noteHostSurfaceClosed(hostStableSurfaceID: UUID) async {
        await detach(hostStableSurfaceID: hostStableSurfaceID, reason: .hostSurfaceClosed)
    }

    /// App/window teardown — cancel all attachments and release handoffs.
    public func teardown() async {
        let ids = Array(attachments.keys)
        for id in ids {
            await detach(hostStableSurfaceID: id, reason: .hostWindowTeardown)
        }
        generationTokens.removeAll()
        topologyReducers.removeAll()
        proposals.removeAll()
        publishPersistenceIntents()
    }

    /// Resolves a live attachment for action routing (PR5). Stale/disconnected reject.
    public func resolveLiveAttachment(
        hostStableSurfaceID: UUID,
        expectedAttachmentID: UUID?,
        expectedProviderInstanceID: NestedProviderInstanceID?
    ) throws -> NestedAttachmentRecord {
        guard let record = attachments[hostStableSurfaceID] else {
            throw NestedAttachmentError.attachmentNotFound(
                hostStableSurfaceID: hostStableSurfaceID
            )
        }
        guard record.state == .live else {
            throw NestedAttachmentError.invalidState(record.state)
        }
        if let expectedAttachmentID, record.attachmentID != expectedAttachmentID {
            throw NestedAttachmentError.providerInstanceMismatch
        }
        if let expectedProviderInstanceID,
           record.providerInstanceID != expectedProviderInstanceID
        {
            throw NestedAttachmentError.providerInstanceMismatch
        }
        return record
    }

    /// Capability-gated focus for one virtual nested node.
    ///
    /// Resolves host surface + attachment generation atomically before send,
    /// forwards typed JSON via the retained provider client, and reconciles
    /// topology from provider events (no optimistic focus invention).
    @discardableResult
    public func focusNode(_ request: NestedNodeFocusRequest) async throws -> NestedNodeFocusResult {
        guard let authorization = request.authorization, authorization.isExplicitOptIn else {
            throw NestedAttachmentError.optInRequired
        }
        try validateAuthorizationRequestID(authorization)

        let record = try resolveLiveAttachment(
            hostStableSurfaceID: request.hostStableSurfaceID,
            expectedAttachmentID: request.expectedAttachmentID,
            expectedProviderInstanceID: request.expectedProviderInstanceID
        )

        guard record.capabilities.contains(.topologyFocusV1) else {
            throw NestedAttachmentError.capabilityAbsent(.topologyFocusV1)
        }
        guard let providerInstanceID = record.providerInstanceID else {
            throw NestedAttachmentError.invalidState(record.state)
        }
        guard request.nodeID.providerKind == record.providerKind else {
            throw NestedAttachmentError.wrongHostSurface
        }
        guard request.nodeID.providerInstanceID == providerInstanceID else {
            throw NestedAttachmentError.providerInstanceMismatch
        }
        guard let snapshot = record.latestSnapshot else {
            throw NestedAttachmentError.invalidState(record.state)
        }
        guard snapshot.hostStableSurfaceID == request.hostStableSurfaceID else {
            throw NestedAttachmentError.wrongHostSurface
        }
        guard Self.containsNode(request.nodeID, in: snapshot) else {
            throw NestedAttachmentError.nodeNotFound(request.nodeID)
        }
        guard let client = liveClients[request.hostStableSurfaceID] else {
            throw NestedAttachmentError.invalidState(record.state)
        }

        let generation = generationTokens[request.hostStableSurfaceID]

        do {
            try await client.focus(nodeID: request.nodeID)
        } catch let error as NestedTopologyProviderError {
            if case .providerError(let code, _) = error, code == "capability_absent" {
                throw NestedAttachmentError.capabilityAbsent(.topologyFocusV1)
            }
            throw NestedAttachmentError.providerFailed(detail: error.localizedDescription)
        } catch {
            throw NestedAttachmentError.providerFailed(
                detail: String(describing: type(of: error))
            )
        }

        // Re-resolve atomically after the await — reject stale/detached races.
        guard generationTokens[request.hostStableSurfaceID] == generation,
              let post = attachments[request.hostStableSurfaceID],
              post.state == .live,
              post.attachmentID == record.attachmentID,
              post.providerInstanceID == providerInstanceID
        else {
            throw NestedAttachmentError.cancelled
        }
        if let postSnapshot = post.latestSnapshot,
           !Self.containsNode(request.nodeID, in: postSnapshot)
        {
            throw NestedAttachmentError.nodeNotFound(request.nodeID)
        }

        emit(
            NestedAttachmentTelemetryEvent(
                name: "focus_accepted",
                state: post.state,
                providerKind: post.providerKind,
                hostStableSurfaceID: request.hostStableSurfaceID,
                attachmentID: post.attachmentID
            )
        )

        return NestedNodeFocusResult(
            hostStableSurfaceID: request.hostStableSurfaceID,
            attachmentID: post.attachmentID,
            providerInstanceID: providerInstanceID,
            nodeID: request.nodeID,
            accepted: true
        )
    }

    // MARK: - Internals


    private func validateAuthorizationRequestID(
        _ authorization: NestedAttachmentAuthorization
    ) throws {
        guard case .authenticatedControlSocket(let requestID) = authorization else { return }
        let sanitized = NestedDisplayStringSanitizer.sanitize(
            requestID,
            maxUTF8ByteCount: limits.maxAuthorizationRequestIDUTF8ByteCount
        )
        if sanitized.utf8.count > limits.maxAuthorizationRequestIDUTF8ByteCount
            || (sanitized.isEmpty && !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        {
            throw NestedAttachmentError.oversizedField("authorization.request_id")
        }
    }

    private func leaveRestoreDisconnected(
        hostStableSurfaceID: UUID,
        intent: NestedAttachmentIntentDescriptor,
        error: NestedAttachmentError,
        generation: UUID? = nil
    ) async -> NestedAttachmentRecord {
        if let generation, generationTokens[hostStableSurfaceID] != generation {
            // A newer attach/detach/teardown superseded this restore attempt.
            return NestedAttachmentRecord(
                hostWorkspaceID: attachments[hostStableSurfaceID]?.hostWorkspaceID ?? "",
                hostStableSurfaceID: hostStableSurfaceID,
                providerKind: intent.providerKind,
                state: .disconnected,
                lastErrorClass: NestedAttachmentError.cancelled.telemetryErrorClass,
                pendingRestoreIntent: intent
            )
        }
        if generation != nil {
            eventTasks.removeValue(forKey: hostStableSurfaceID)?.cancel()
            liveClients.removeValue(forKey: hostStableSurfaceID)
            topologyReducers.removeValue(forKey: hostStableSurfaceID)
            liveEnvironmentSurfaceIDs.remove(hostStableSurfaceID)
            publishEnvironmentMirror()
            try? handoff.release(hostStableSurfaceID: hostStableSurfaceID)
        }

        let workspaceID = attachments[hostStableSurfaceID]?.hostWorkspaceID ?? ""
        let attachmentID = attachments[hostStableSurfaceID]?.attachmentID ?? UUID()
        let state: NestedConnectionState
        switch error {
        case .endpointRejected:
            state = .rejected
        case .incompatibleProvider:
            state = .incompatible
        default:
            state = .disconnected
        }

        let record = NestedAttachmentRecord(
            attachmentID: attachmentID,
            hostWorkspaceID: workspaceID,
            hostStableSurfaceID: hostStableSurfaceID,
            providerKind: intent.providerKind,
            endpoint: nil,
            providerInstanceID: nil,
            providerInstanceIdentityProofAvailable: false,
            capabilities: NestedCapabilitySet(),
            state: state,
            pluginWriterHandoffActive: false,
            lastErrorClass: error.telemetryErrorClass,
            latestSnapshot: nil,
            pendingRestoreIntent: intent
        )
        attachments[hostStableSurfaceID] = record
        emit(
            NestedAttachmentTelemetryEvent(
                name: "restore_disconnected",
                state: state,
                providerKind: intent.providerKind,
                errorClass: error.telemetryErrorClass,
                hostStableSurfaceID: hostStableSurfaceID,
                attachmentID: attachmentID
            )
        )
        return record
    }

    private func detach(
        hostStableSurfaceID: UUID,
        reason: NestedDetachReason,
        emitTelemetry: Bool
    ) async {
        generationTokens.removeValue(forKey: hostStableSurfaceID)
        eventTasks.removeValue(forKey: hostStableSurfaceID)?.cancel()
        liveClients.removeValue(forKey: hostStableSurfaceID)
        topologyReducers.removeValue(forKey: hostStableSurfaceID)

        let previous = attachments.removeValue(forKey: hostStableSurfaceID)
        liveEnvironmentSurfaceIDs.remove(hostStableSurfaceID)
        publishEnvironmentMirror()
        try? handoff.release(hostStableSurfaceID: hostStableSurfaceID)

        if emitTelemetry, let previous {
            emit(
                NestedAttachmentTelemetryEvent(
                    name: "detached",
                    state: .disconnected,
                    providerKind: previous.providerKind,
                    errorClass: reason.rawValue,
                    hostStableSurfaceID: hostStableSurfaceID,
                    attachmentID: previous.attachmentID
                )
            )
        }
    }

    private func failAttachment(
        hostStableSurfaceID: UUID,
        generation: UUID,
        state: NestedConnectionState,
        error: NestedAttachmentError,
        remove: Bool
    ) async {
        guard generationTokens[hostStableSurfaceID] == generation else { return }
        eventTasks.removeValue(forKey: hostStableSurfaceID)?.cancel()
        liveClients.removeValue(forKey: hostStableSurfaceID)
        topologyReducers.removeValue(forKey: hostStableSurfaceID)
        liveEnvironmentSurfaceIDs.remove(hostStableSurfaceID)
        publishEnvironmentMirror()
        try? handoff.release(hostStableSurfaceID: hostStableSurfaceID)

        let previous = attachments[hostStableSurfaceID]
        if remove {
            attachments.removeValue(forKey: hostStableSurfaceID)
        } else if var record = attachments[hostStableSurfaceID] {
            record.state = state
            record.pluginWriterHandoffActive = false
            record.lastErrorClass = error.telemetryErrorClass
            if state == .rejected || state == .incompatible || state == .disconnected {
                // Keep endpoint identity metadata only for rejected/incompatible diagnostics
                // in memory; never publish path via telemetry.
                record.latestSnapshot = nil
            }
            attachments[hostStableSurfaceID] = record
        }

        emit(
            NestedAttachmentTelemetryEvent(
                name: "attach_failed",
                state: state,
                providerKind: attachments[hostStableSurfaceID]?.providerKind ?? previous?.providerKind,
                errorClass: error.telemetryErrorClass,
                hostStableSurfaceID: hostStableSurfaceID,
                attachmentID: attachments[hostStableSurfaceID]?.attachmentID ?? previous?.attachmentID
            )
        )
    }

    private func startEventObservation(
        hostStableSurfaceID: UUID,
        generation: UUID,
        client: any NestedTopologyProviderClient
    ) {
        eventTasks[hostStableSurfaceID]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            let stream = client.events()
            do {
                for try await event in stream {
                    try Task.checkCancellation()
                    await self.applyEvent(
                        event,
                        hostStableSurfaceID: hostStableSurfaceID,
                        generation: generation
                    )
                }
                await self.markStale(
                    hostStableSurfaceID: hostStableSurfaceID,
                    generation: generation,
                    errorClass: NestedTopologyProviderError.unexpectedEOF.telemetryErrorClass
                )
            } catch is CancellationError {
                return
            } catch let error as NestedTopologyProviderError {
                if case .cancelled = error { return }
                await self.markStale(
                    hostStableSurfaceID: hostStableSurfaceID,
                    generation: generation,
                    errorClass: error.telemetryErrorClass
                )
            } catch {
                await self.markStale(
                    hostStableSurfaceID: hostStableSurfaceID,
                    generation: generation,
                    errorClass: "event_stream_failed"
                )
            }
        }
        eventTasks[hostStableSurfaceID] = task
    }

    private func applyEvent(
        _ event: NestedTopologyEvent,
        hostStableSurfaceID: UUID,
        generation: UUID
    ) {
        guard generationTokens[hostStableSurfaceID] == generation,
              var record = attachments[hostStableSurfaceID]
        else {
            return
        }
        if case .replaceSnapshot(let snapshot) = event {
            record.latestSnapshot = snapshot
            record.providerInstanceID = snapshot.provider.providerInstanceID
            record.capabilities = snapshot.provider.capabilities
            var reducer = NestedTopologyReducer(
                providerKind: record.providerKind,
                providerInstanceID: snapshot.provider.providerInstanceID,
                limits: clientConfigurationDefaults.topologyLimits
            )
            do {
                _ = try reducer.apply(.replaceSnapshot(snapshot))
                topologyReducers[hostStableSurfaceID] = reducer
            } catch {
                topologyReducers.removeValue(forKey: hostStableSurfaceID)
            }
            if record.state == .stale {
                record.state = .live
                if !record.pluginWriterHandoffActive {
                    try? handoff.acquire(
                        hostStableSurfaceID: hostStableSurfaceID,
                        attachmentID: record.attachmentID
                    )
                    record.pluginWriterHandoffActive = true
                    liveEnvironmentSurfaceIDs.insert(hostStableSurfaceID)
                    publishEnvironmentMirror()
                }
            }
            attachments[hostStableSurfaceID] = record
            emit(
                NestedAttachmentTelemetryEvent(
                    name: "topology_updated",
                    state: record.state,
                    providerKind: record.providerKind,
                    hostStableSurfaceID: hostStableSurfaceID,
                    attachmentID: record.attachmentID
                )
            )
            return
        }

        // Incremental reconcile (including focusChanged). Never invent topology
        // from mutation RPC success alone — only provider events update focus.
        guard let current = record.latestSnapshot,
              let instanceID = record.providerInstanceID
        else {
            return
        }
        var reducer: NestedTopologyReducer
        if let existing = topologyReducers[hostStableSurfaceID],
           existing.providerInstanceID == instanceID,
           existing.snapshot != nil
        {
            reducer = existing
        } else {
            var seeded = NestedTopologyReducer(
                providerKind: record.providerKind,
                providerInstanceID: instanceID,
                limits: clientConfigurationDefaults.topologyLimits
            )
            do {
                _ = try seeded.apply(.replaceSnapshot(current))
            } catch {
                emit(
                    NestedAttachmentTelemetryEvent(
                        name: "event_rejected",
                        state: record.state,
                        providerKind: record.providerKind,
                        errorClass: "event_validation_failed",
                        hostStableSurfaceID: hostStableSurfaceID,
                        attachmentID: record.attachmentID
                    )
                )
                return
            }
            reducer = seeded
        }
        do {
            let changed = try reducer.apply(event)
            topologyReducers[hostStableSurfaceID] = reducer
            guard changed, let next = reducer.snapshot else { return }
            record.latestSnapshot = next
            attachments[hostStableSurfaceID] = record
            emit(
                NestedAttachmentTelemetryEvent(
                    name: "topology_updated",
                    state: record.state,
                    providerKind: record.providerKind,
                    hostStableSurfaceID: hostStableSurfaceID,
                    attachmentID: record.attachmentID
                )
            )
        } catch {
            // Invalid incremental events do not invent state; keep last good snapshot.
            emit(
                NestedAttachmentTelemetryEvent(
                    name: "event_rejected",
                    state: record.state,
                    providerKind: record.providerKind,
                    errorClass: "event_validation_failed",
                    hostStableSurfaceID: hostStableSurfaceID,
                    attachmentID: record.attachmentID
                )
            )
        }
    }

    private static func containsNode(
        _ nodeID: NestedNodeID,
        in snapshot: NestedTopologySnapshot
    ) -> Bool {
        switch nodeID.kind {
        case .workspace:
            return snapshot.workspaces.contains { $0.id == nodeID }
        case .tab:
            return snapshot.tabs.contains { $0.id == nodeID }
        case .pane:
            return snapshot.panes.contains { $0.id == nodeID }
        case .agent:
            return snapshot.agents.contains { $0.id == nodeID }
        }
    }

    private func markStale(
        hostStableSurfaceID: UUID,
        generation: UUID,
        errorClass: String
    ) {
        guard generationTokens[hostStableSurfaceID] == generation,
              var record = attachments[hostStableSurfaceID],
              record.state == .live || record.state == .stale
        else {
            return
        }
        record.state = .stale
        record.lastErrorClass = errorClass
        // Leaving live: release plugin handoff so fallback may resume.
        if record.pluginWriterHandoffActive {
            try? handoff.release(hostStableSurfaceID: hostStableSurfaceID)
            record.pluginWriterHandoffActive = false
            liveEnvironmentSurfaceIDs.remove(hostStableSurfaceID)
            publishEnvironmentMirror()
        }
        attachments[hostStableSurfaceID] = record
        emit(
            NestedAttachmentTelemetryEvent(
                name: "became_stale",
                state: .stale,
                providerKind: record.providerKind,
                errorClass: errorClass,
                hostStableSurfaceID: hostStableSurfaceID,
                attachmentID: record.attachmentID
            )
        )
    }

    private func publishEnvironmentMirror() {
        let value = NestedPluginWriterHandoff.environmentValue(
            for: Array(liveEnvironmentSurfaceIDs)
        )
        environmentMirrorSink?(value)
    }

    private func emit(_ event: NestedAttachmentTelemetryEvent) {
        publishPersistenceIntents()
        telemetrySink?(event)
    }

    private func publishPersistenceIntents() {
        var next: [UUID: NestedAttachmentIntentDescriptor] = [:]
        for (hostStableSurfaceID, record) in attachments {
            if let intent = record.sessionPersistenceIntent ?? record.pendingRestoreIntent {
                next[hostStableSurfaceID] = intent
            }
        }
        persistenceIntents.replace(next)
    }
}

extension NestedTopologyProviderError {
    fileprivate var telemetryErrorClass: String {
        switch self {
        case .connectTimeout: return "connect_timeout"
        case .requestTimeout: return "request_timeout"
        case .unexpectedEOF: return "unexpected_eof"
        case .oversizedLine: return "oversized_line"
        case .oversizedSnapshot: return "oversized_snapshot"
        case .oversizedEvent: return "oversized_event"
        case .invalidUTF8: return "invalid_utf8"
        case .malformedJSON: return "malformed_json"
        case .responseIDMismatch: return "response_id_mismatch"
        case .providerError: return "provider_error"
        case .missingRequiredField: return "missing_required_field"
        case .unsupportedProtocol: return "unsupported_protocol"
        case .cancelled: return "cancelled"
        case .transport: return "transport"
        }
    }
}
