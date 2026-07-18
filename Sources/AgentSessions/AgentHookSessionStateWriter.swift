import CmuxFoundation
import CmuxControlSocket
import CmuxSettings
import Darwin
import Foundation

/// Completes a hook-store session after cmux observes the root TUI return to its
/// shell prompt. Work runs on a utility-priority task and uses the same sidecar lock as
/// hook writers, so terminal UI delivery never waits on disk or JSON work.
struct AgentHookSessionStateWriter: Sendable {
    /// The hook stores are process-wide files, so app-originated mutations share
    /// one actor. Timestamp fences make each mutation safe even if independently
    /// created tasks reach this actor in a different order.
    private actor WriteCoordinator {
        func complete(
            using writer: AgentHookSessionStateWriter,
            provider: String,
            stateURL: URL,
            sessionId: String,
            expectedRecordUpdatedAt: TimeInterval?,
            now: TimeInterval
        ) {
            writer.complete(
                provider: provider,
                stateURL: stateURL,
                sessionId: sessionId,
                expectedRecordUpdatedAt: expectedRecordUpdatedAt,
                now: now
            )
        }

        func setLifecycle(
            _ lifecycle: AgentSessionLifecycleState,
            using writer: AgentHookSessionStateWriter,
            provider: String,
            stateURL: URL,
            sessionId: String,
            now: TimeInterval
        ) {
            writer.setLifecycle(
                lifecycle,
                provider: provider,
                stateURL: stateURL,
                sessionId: sessionId,
                now: now
            )
        }

        func projectRestoredHibernationsToLegacy(
            using writer: AgentHookSessionStateWriter,
            provider: String,
            stateURL: URL,
            requests: [RestoredHibernationAdoptionRequest],
            now: TimeInterval
        ) {
            writer.projectRestoredHibernationsToLegacy(
                provider: provider,
                stateURL: stateURL,
                requests: requests,
                now: now
            )
        }

        func projectHibernatedResumesToLegacy(
            using writer: AgentHookSessionStateWriter,
            provider: String,
            stateURL: URL,
            claims: [HibernatedResumeAuthorityClaim],
            now: TimeInterval
        ) {
            writer.projectHibernatedResumesToLegacy(
                provider: provider,
                stateURL: stateURL,
                claims: claims,
                now: now
            )
        }

        func projectEstablishedHibernationToLegacy(
            using writer: AgentHookSessionStateWriter,
            provider: String,
            stateURL: URL,
            request: HibernatedResumeAuthorityRequest,
            legacyStampAtClaim: CmuxAgentSessionRegistry.LegacyStamp?,
            now: TimeInterval
        ) {
            writer.projectEstablishedHibernationToLegacy(
                provider: provider,
                stateURL: stateURL,
                request: request,
                legacyStampAtClaim: legacyStampAtClaim,
                now: now
            )
        }

        func projectCanonicalLegacy(
            using writer: AgentHookSessionStateWriter,
            provider: String,
            stateURL: URL
        ) {
            writer.projectCanonicalLegacy(provider: provider, stateURL: stateURL)
        }

    }

    private static let writeCoordinator = WriteCoordinator()
    struct RestoredHibernationAdoptionRequest: Sendable {
        var agent: SessionRestorableAgentSnapshot
        var previousWorkspaceId: UUID?
        var previousSurfaceId: UUID
        var workspaceId: UUID
        var surfaceId: UUID
        var rebindWorkspaceActiveSlot = false
        var adoptionId = UUID()
    }
    enum RestoredHibernationAdoptionOutcome: Equatable, Sendable {
        case adopted
        case rejected
        case unavailable
    }
    struct HibernatedResumeAuthorityRequest: Sendable {
        var agent: SessionRestorableAgentSnapshot
        var workspaceId: UUID
        var surfaceId: UUID
    }
    enum HibernatedResumeAuthorityOutcome: Equatable, Sendable {
        case acquired
        case rejected
        case unavailable
    }
    struct HibernatedResumeAuthorityClaim: Sendable {
        var request: HibernatedResumeAuthorityRequest
        var legacyStampAtClaim: CmuxAgentSessionRegistry.LegacyStamp?
    }
    private struct RestoredHibernationOwnerPreflight: Sendable {
        let recordFingerprint: Data
        let hasProvablyLiveForeignRuntime: Bool
    }
    private enum LegacyReadLockMode: Sendable, Equatable {
        case immediate
        case wait
    }
    private struct MonotonicBusyBudget: Sendable {
        private let deadlineNanoseconds: UInt64

        init(milliseconds: Int32) {
            let now = DispatchTime.now().uptimeNanoseconds
            let duration = UInt64(max(0, milliseconds)).multipliedReportingOverflow(by: 1_000_000)
            if duration.overflow {
                deadlineNanoseconds = .max
            } else {
                deadlineNanoseconds = now.addingReportingOverflow(duration.partialValue).overflow
                    ? .max
                    : now + duration.partialValue
            }
        }

        func remainingMilliseconds() -> Int32 {
            let remainingNanoseconds = remainingNanoseconds()
            let roundedUpMilliseconds = remainingNanoseconds / 1_000_000
                + (remainingNanoseconds % 1_000_000 == 0 ? 0 : 1)
            return Int32(min(UInt64(Int32.max), roundedUpMilliseconds))
        }

        func remainingNanoseconds() -> UInt64 {
            let now = DispatchTime.now().uptimeNanoseconds
            return now < deadlineNanoseconds ? deadlineNanoseconds - now : 0
        }
    }
    private final class LegacyLockCancellationSignal: @unchecked Sendable {
        let readDescriptor: Int32
        private let writeDescriptor: Int32

        init?() {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard pipe(&descriptors) == 0 else { return nil }
            readDescriptor = descriptors[0]
            writeDescriptor = descriptors[1]
            _ = fcntl(readDescriptor, F_SETFD, FD_CLOEXEC)
            _ = fcntl(writeDescriptor, F_SETFD, FD_CLOEXEC)
            _ = fcntl(writeDescriptor, F_SETFL, O_NONBLOCK)
        }

        deinit {
            Darwin.close(readDescriptor)
            Darwin.close(writeDescriptor)
        }

        func cancel() {
            var byte: UInt8 = 1
            _ = withUnsafePointer(to: &byte) {
                Darwin.write(writeDescriptor, $0, 1)
            }
        }
    }
    typealias CurrentSocketStateResolver = @Sendable (
        _ preferredPath: String
    ) -> (activePath: String, pathOwnedByCurrentListener: Bool)
    private let homeDirectory: String
    private let environment: [String: String]
    private let currentSocketStateResolver: CurrentSocketStateResolver

    init(
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentSocketStateResolver: @escaping CurrentSocketStateResolver = { preferredPath in
            let activePath = TerminalController.shared.activeSocketPath(
                preferredPath: preferredPath
            )
            return (
                activePath,
                TerminalController.shared.socketListenerHealth(
                    expectedSocketPath: activePath
                ).socketPathOwnedByListener
            )
        }
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.currentSocketStateResolver = currentSocketStateResolver
    }

    static func rootExitCandidate(
        previousWasRunning: Bool,
        isPromptIdle: Bool,
        isHibernated: Bool,
        binding: SurfaceResumeBindingSnapshot?
    ) -> SurfaceResumeBindingSnapshot? {
        previousWasRunning && isPromptIdle && !isHibernated && binding?.isAgentHookBinding == true
            ? binding
            : nil
    }

    static func recordRootExitIfNeeded(
        binding: SurfaceResumeBindingSnapshot?
    ) {
        guard let kindValue = binding?.kind,
              let kind = RestorableAgentKind(rawValue: kindValue),
              let sessionId = binding?.checkpointId else { return }
        AgentHookSessionStateWriter().schedule(
            kind: kind,
            sessionId: sessionId,
            expectedRecordUpdatedAt: binding?.updatedAt
        )
    }

    static func recordLifecycle(
        agent: SessionRestorableAgentSnapshot?,
        state: AgentSessionLifecycleState
    ) {
        guard let agent else { return }
        AgentHookSessionStateWriter().scheduleLifecycle(
            kind: agent.kind,
            sessionId: agent.sessionId,
            state: state
        )
    }

    @discardableResult
    static func recordRestoredHibernation(
        agent: SessionRestorableAgentSnapshot,
        previousWorkspaceId: UUID?,
        previousSurfaceId: UUID,
        workspaceId: UUID,
        surfaceId: UUID
    ) -> Bool {
        recordRestoredHibernations([
            RestoredHibernationAdoptionRequest(
                agent: agent,
                previousWorkspaceId: previousWorkspaceId,
                previousSurfaceId: previousSurfaceId,
                workspaceId: workspaceId,
                surfaceId: surfaceId
            ),
        ]).contains(surfaceId)
    }

    static func recordRestoredHibernations(
        _ requests: [RestoredHibernationAdoptionRequest],
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Set<UUID> {
        Set(recordRestoredHibernationOutcomes(requests, now: now).compactMap {
            $0.value == .adopted ? $0.key : nil
        })
    }

    static func recordRestoredHibernationOutcomes(
        _ requests: [RestoredHibernationAdoptionRequest],
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> [UUID: RestoredHibernationAdoptionOutcome] {
        AgentHookSessionStateWriter().recordRestoredHibernationOutcomesSynchronously(
            requests,
            now: now
        )
    }

    /// Waits once for an in-flight registry writer, then claims every restored
    /// hibernation in the same provider-batched transactions used by restore.
    /// Cancellation is checked inside the acquired transaction before any row
    /// is changed, so closing a pending panel cannot apply a delayed claim.
    static func waitForRestoredHibernationOutcomes(
        _ requests: [RestoredHibernationAdoptionRequest],
        now: TimeInterval = Date().timeIntervalSince1970,
        busyTimeoutMilliseconds: Int32 = 2_000,
        legacyReadLockWaitWillBegin: @escaping @Sendable () -> Void = {}
    ) async -> [UUID: RestoredHibernationAdoptionOutcome] {
        guard !requests.isEmpty else { return [:] }
        let writer = AgentHookSessionStateWriter()
        let cancellationSignal = LegacyLockCancellationSignal()
        let operation = Task.detached(priority: .utility) {
            writer.recordRestoredHibernationOutcomesSynchronously(
                requests,
                now: now,
                busyTimeoutMilliseconds: max(0, busyTimeoutMilliseconds),
                legacyReadLockMode: .wait,
                legacyReadLockWaitWillBegin: legacyReadLockWaitWillBegin,
                legacyReadLockCancellationDescriptor: cancellationSignal?.readDescriptor,
                cancellationCheck: { Task.isCancelled }
            )
        }
        return await withTaskCancellationHandler(
            operation: { await operation.value },
            onCancel: {
                cancellationSignal?.cancel()
                operation.cancel()
            }
        )
    }

    /// Completes only the exact adoption generation written by a delayed
    /// background claim. A newer retry or resume replaces/removes the token,
    /// making this compensation a no-op instead of revoking its authority.
    static func releaseCanceledRestoredHibernations(
        _ requests: [RestoredHibernationAdoptionRequest],
        now: TimeInterval = Date().timeIntervalSince1970
    ) async {
        guard !requests.isEmpty else { return }
        let writer = AgentHookSessionStateWriter()
        await Task.detached(priority: .utility) {
            writer.releaseCanceledRestoredHibernationsSynchronously(
                requests,
                now: now
            )
        }.value
    }

    /// Atomically claims the durable surface owner immediately before cmux
    /// queues a hibernated agent's resume input. A missing or changed slot is a
    /// lost authority lease, even when the record still carries the old binding.
    @discardableResult
    static func acquireHibernatedResumeAuthority(
        agent: SessionRestorableAgentSnapshot,
        workspaceId: UUID,
        surfaceId: UUID,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> HibernatedResumeAuthorityOutcome {
        acquireHibernatedResumeAuthorities([
            HibernatedResumeAuthorityRequest(
                agent: agent,
                workspaceId: workspaceId,
                surfaceId: surfaceId
            ),
        ], now: now)[surfaceId] ?? .unavailable
    }

    /// Claims many hibernated records with one bounded SQLite transaction per
    /// provider. Rejected siblings do not prevent independent claims from
    /// succeeding in the same transaction.
    static func acquireHibernatedResumeAuthorities(
        _ requests: [HibernatedResumeAuthorityRequest],
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> [UUID: HibernatedResumeAuthorityOutcome] {
        AgentHookSessionStateWriter().acquireHibernatedResumeAuthoritiesSynchronously(
            requests,
            now: now
        )
    }

    /// Establishes the durable hibernated lease at the native teardown commit
    /// point. Failure leaves the live runtime intact and retryable.
    static func establishHibernatedAuthority(
        agent: SessionRestorableAgentSnapshot,
        workspaceId: UUID,
        surfaceId: UUID,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> HibernatedResumeAuthorityOutcome {
        AgentHookSessionStateWriter().establishHibernatedAuthoritySynchronously(
            request: HibernatedResumeAuthorityRequest(
                agent: agent,
                workspaceId: workspaceId,
                surfaceId: surfaceId
            ),
            now: now
        )
    }

    private func recordRestoredHibernationOutcomesSynchronously(
        _ requests: [RestoredHibernationAdoptionRequest],
        now: TimeInterval,
        busyTimeoutMilliseconds: Int32 = 25,
        legacyReadLockMode: LegacyReadLockMode = .immediate,
        legacyReadLockWaitWillBegin: @escaping @Sendable () -> Void = {},
        legacyReadLockCancellationDescriptor: Int32? = nil,
        cancellationCheck: @Sendable () -> Bool = { false }
    ) -> [UUID: RestoredHibernationAdoptionOutcome] {
        var outcomes: [UUID: RestoredHibernationAdoptionOutcome] = [:]
        let busyBudget = MonotonicBusyBudget(milliseconds: busyTimeoutMilliseconds)
        let requestsByProvider = Dictionary(grouping: requests, by: { $0.agent.kind.rawValue })
            .sorted { $0.key < $1.key }
        for (provider, providerRequests) in requestsByProvider {
            guard !cancellationCheck() else { break }
            guard let kind = providerRequests.first?.agent.kind else { continue }
            let stateURL = kind.hookStoreFileURL(
                homeDirectory: homeDirectory,
                environment: environment
            )
            let providerResult = adoptRestoredHibernationsHoldingLegacyReadLock(
                provider: provider,
                stateURL: stateURL,
                requests: providerRequests,
                now: now,
                busyBudget: busyBudget,
                legacyReadLockMode: legacyReadLockMode,
                legacyReadLockWaitWillBegin: legacyReadLockWaitWillBegin,
                legacyReadLockCancellationDescriptor: legacyReadLockCancellationDescriptor,
                cancellationCheck: cancellationCheck
            )
            outcomes.merge(providerResult.outcomes) { _, new in new }
            let adopted = providerResult.adopted
            guard !adopted.isEmpty else { continue }
            Task(priority: .utility) {
                await Self.writeCoordinator.projectRestoredHibernationsToLegacy(
                    using: self,
                    provider: provider,
                    stateURL: stateURL,
                    requests: adopted,
                    now: now
                )
            }
        }
        return outcomes
    }

    private func releaseCanceledRestoredHibernationsSynchronously(
        _ requests: [RestoredHibernationAdoptionRequest],
        now: TimeInterval
    ) {
        let busyBudget = MonotonicBusyBudget(milliseconds: 2_000)
        let requestsByProvider = Dictionary(
            grouping: requests,
            by: { $0.agent.kind.rawValue }
        ).sorted { $0.key < $1.key }
        for (provider, providerRequests) in requestsByProvider {
            guard let kind = providerRequests.first?.agent.kind else { continue }
            let stateURL = kind.hookStoreFileURL(
                homeDirectory: homeDirectory,
                environment: environment
            )
            let normalizedRequests = providerRequests.compactMap {
                request -> (RestoredHibernationAdoptionRequest, String)? in
                guard let sessionId = normalized(request.agent.sessionId) else { return nil }
                return (request, sessionId)
            }
            guard !normalizedRequests.isEmpty else { continue }
            do {
                try registry(
                    provider: provider,
                    stateURL: stateURL,
                    busyTimeoutMilliseconds: busyBudget.remainingMilliseconds()
                ).withRecordRebindBatch { batch in
                    for (request, sessionId) in normalizedRequests {
                        let result = try batch.patchRecordRebindingActiveSlots(
                            provider: provider,
                            sessionID: sessionId,
                            updatedAt: now,
                            previousSlots: [
                                .init(scope: .workspace, scopeID: request.workspaceId.uuidString),
                                .init(scope: .surface, scopeID: request.surfaceId.uuidString),
                            ],
                            activeSlots: [],
                            monotonicUpdatedAt: true,
                            shouldMutate: { record in
                                guard normalized(record["cmuxRestoreAdoptionId"] as? String)
                                        == request.adoptionId.uuidString,
                                      record["sessionState"] as? String
                                        == AgentSessionLifecycleState.hibernated.rawValue,
                                      record["restoreAuthority"] as? Bool != false,
                                      !hasCompletion(record),
                                      recordBelongsToCurrentRuntime(record),
                                      let workspaceId = normalized(record["workspaceId"] as? String),
                                      let surfaceId = normalized(record["surfaceId"] as? String) else {
                                    return false
                                }
                                return identifiersEqual(workspaceId, request.workspaceId.uuidString)
                                    && identifiersEqual(surfaceId, request.surfaceId.uuidString)
                            }
                        ) { record in
                            let effectiveNow = max(
                                now,
                                record["updatedAt"] as? TimeInterval ?? now
                            )
                            applyCompletion(to: &record, now: effectiveNow)
                            record.removeValue(forKey: "cmuxRestoreAdoptionId")
                        }
                        if result == .patched {
                            NSLog(
                                "[Workspace] released canceled restored hibernation session=%@ surface=%@",
                                sessionId,
                                request.surfaceId.uuidString
                            )
                        }
                    }
                }
                Task(priority: .utility) {
                    await Self.writeCoordinator.projectCanonicalLegacy(
                        using: self,
                        provider: provider,
                        stateURL: stateURL
                    )
                }
            } catch {
                NSLog(
                    "[Workspace] failed to release canceled restored hibernation provider=%@ error=%@",
                    provider,
                    String(describing: error)
                )
            }
        }
    }

    func schedule(
        kind: RestorableAgentKind,
        sessionId: String,
        expectedRecordUpdatedAt: TimeInterval? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        let normalized = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let stateURL = kind.hookStoreFileURL(
            homeDirectory: homeDirectory,
            environment: environment
        )
        Task(priority: .utility) {
            await Self.writeCoordinator.complete(
                using: self,
                provider: kind.rawValue,
                stateURL: stateURL,
                sessionId: normalized,
                expectedRecordUpdatedAt: expectedRecordUpdatedAt,
                now: now
            )
        }
    }

    func completeSynchronously(
        kind: RestorableAgentKind,
        sessionId: String,
        expectedRecordUpdatedAt: TimeInterval? = nil,
        now: TimeInterval
    ) {
        let normalized = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        complete(
            provider: kind.rawValue,
            stateURL: kind.hookStoreFileURL(
                homeDirectory: homeDirectory,
                environment: environment
            ),
            sessionId: normalized,
            expectedRecordUpdatedAt: expectedRecordUpdatedAt,
            now: now
        )
    }

    func scheduleLifecycle(
        kind: RestorableAgentKind,
        sessionId: String,
        state: AgentSessionLifecycleState,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        let normalized = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let stateURL = kind.hookStoreFileURL(
            homeDirectory: homeDirectory,
            environment: environment
        )
        Task(priority: .utility) {
            await Self.writeCoordinator.setLifecycle(
                state,
                using: self,
                provider: kind.rawValue,
                stateURL: stateURL,
                sessionId: normalized,
                now: now
            )
        }
    }

    func setLifecycleSynchronously(
        kind: RestorableAgentKind,
        sessionId: String,
        state: AgentSessionLifecycleState,
        now: TimeInterval
    ) {
        let normalized = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        setLifecycle(
            state,
            provider: kind.rawValue,
            stateURL: kind.hookStoreFileURL(
                homeDirectory: homeDirectory,
                environment: environment
            ),
            sessionId: normalized,
            now: now
        )
    }

    @discardableResult
    func recordRestoredHibernationSynchronously(
        kind: RestorableAgentKind,
        sessionId: String,
        previousWorkspaceId: String?,
        previousSurfaceId: String,
        workspaceId: String,
        surfaceId: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard let normalizedSessionId = normalized(sessionId),
              let normalizedPreviousSurfaceId = normalized(previousSurfaceId),
              let normalizedWorkspaceId = normalized(workspaceId),
              let normalizedSurfaceId = normalized(surfaceId),
              let previousSurfaceUUID = UUID(uuidString: normalizedPreviousSurfaceId),
              let workspaceUUID = UUID(uuidString: normalizedWorkspaceId),
              let surfaceUUID = UUID(uuidString: normalizedSurfaceId) else { return false }
        let previousWorkspaceUUID: UUID?
        if let previousWorkspaceId {
            guard let value = normalized(previousWorkspaceId),
                  let uuid = UUID(uuidString: value) else { return false }
            previousWorkspaceUUID = uuid
        } else {
            previousWorkspaceUUID = nil
        }
        let request = RestoredHibernationAdoptionRequest(
            agent: SessionRestorableAgentSnapshot(
                kind: kind,
                sessionId: normalizedSessionId,
                workingDirectory: nil,
                launchCommand: nil
            ),
            previousWorkspaceId: previousWorkspaceUUID,
            previousSurfaceId: previousSurfaceUUID,
            workspaceId: workspaceUUID,
            surfaceId: surfaceUUID
        )
        return recordRestoredHibernationOutcomesSynchronously(
            [request],
            now: now
        )[surfaceUUID] == .adopted
    }

    private func complete(
        provider: String,
        stateURL: URL,
        sessionId: String,
        expectedRecordUpdatedAt: TimeInterval?,
        now: TimeInterval
    ) {
        let registry = preparedRegistry(provider: provider, stateURL: stateURL)
        _ = try? registry.patchRecord(
            provider: provider,
            sessionID: sessionId,
            updatedAt: now,
            activeSlotRemoval: expectedRecordUpdatedAt.map {
                .updatedThrough($0)
            } ?? .all,
            shouldMutate: { record in
                guard let expectedRecordUpdatedAt else { return true }
                guard let actualUpdatedAt = record["updatedAt"] as? TimeInterval else { return false }
                return actualUpdatedAt <= expectedRecordUpdatedAt
            }
        ) { registryRecord in
            applyCompletion(to: &registryRecord, now: now)
        }

        projectCanonicalLegacy(provider: provider, stateURL: stateURL)
    }

    private func setLifecycle(
        _ lifecycle: AgentSessionLifecycleState,
        provider: String,
        stateURL: URL,
        sessionId: String,
        now: TimeInterval
    ) {
        let registry = preparedRegistry(provider: provider, stateURL: stateURL)
        _ = try? registry.patchRecord(
            provider: provider,
            sessionID: sessionId,
            updatedAt: now,
            shouldMutate: { record in
                guard let actualUpdatedAt = record["updatedAt"] as? TimeInterval else { return false }
                return actualUpdatedAt <= now
            }
        ) { registryRecord in
            applyLifecycle(lifecycle, to: &registryRecord, now: now)
        }
        projectCanonicalLegacy(provider: provider, stateURL: stateURL)
    }

    private func establishHibernatedAuthoritySynchronously(
        request: HibernatedResumeAuthorityRequest,
        now: TimeInterval
    ) -> HibernatedResumeAuthorityOutcome {
        guard let sessionId = normalized(request.agent.sessionId) else { return .rejected }
        let provider = request.agent.kind.rawValue
        let stateURL = request.agent.kind.hookStoreFileURL(
            homeDirectory: homeDirectory,
            environment: environment
        )
        let legacyStampAtClaim = CmuxAgentSessionRegistry.LegacyStamp.read(path: stateURL.path)
        let result: CmuxAgentSessionRegistry.RecordRebindResult
        do {
            result = try registry(
                provider: provider,
                stateURL: stateURL,
                busyTimeoutMilliseconds: 25
            ).patchRecordRebindingActiveSlots(
                provider: provider,
                sessionID: sessionId,
                updatedAt: now,
                previousSlots: [],
                activeSlots: [.init(scope: .surface, scopeID: request.surfaceId.uuidString)],
                requireExistingActiveSlots: true,
                monotonicUpdatedAt: true,
                shouldMutate: { record in
                    let allowedStates: Set<String> = [
                        AgentSessionLifecycleState.active.rawValue,
                        AgentSessionLifecycleState.restoring.rawValue,
                        AgentSessionLifecycleState.hibernated.rawValue,
                    ]
                    guard let state = record["sessionState"] as? String,
                          allowedStates.contains(state),
                          record["restoreAuthority"] as? Bool != false,
                          !hasCompletion(record),
                          record["updatedAt"] is TimeInterval,
                          recordBelongsToCurrentRuntime(record),
                          let recordWorkspaceId = normalized(record["workspaceId"] as? String),
                          let recordSurfaceId = normalized(record["surfaceId"] as? String) else {
                        return false
                    }
                    return identifiersEqual(recordWorkspaceId, request.workspaceId.uuidString)
                        && identifiersEqual(recordSurfaceId, request.surfaceId.uuidString)
                }
            ) { record in
                let effectiveNow = max(now, record["updatedAt"] as? TimeInterval ?? now)
                applyLifecycle(.hibernated, to: &record, now: effectiveNow)
                record.removeValue(forKey: "cmuxRestoreAdoptionId")
            }
        } catch {
            return .unavailable
        }
        guard result == .patched else { return .rejected }
        Task(priority: .utility) {
            await Self.writeCoordinator.projectEstablishedHibernationToLegacy(
                using: self,
                provider: provider,
                stateURL: stateURL,
                request: request,
                legacyStampAtClaim: legacyStampAtClaim,
                now: now
            )
        }
        return .acquired
    }

    private func acquireHibernatedResumeAuthoritiesSynchronously(
        _ requests: [HibernatedResumeAuthorityRequest],
        now: TimeInterval
    ) -> [UUID: HibernatedResumeAuthorityOutcome] {
        var outcomes: [UUID: HibernatedResumeAuthorityOutcome] = [:]
        let busyBudget = MonotonicBusyBudget(milliseconds: 25)
        let requestsByProvider = Dictionary(
            grouping: requests,
            by: { $0.agent.kind.rawValue }
        ).sorted { $0.key < $1.key }
        for (provider, providerRequests) in requestsByProvider {
            guard let kind = providerRequests.first?.agent.kind else { continue }
            let stateURL = kind.hookStoreFileURL(
                homeDirectory: homeDirectory,
                environment: environment
            )
            let normalizedRequests = providerRequests.compactMap {
                request -> (request: HibernatedResumeAuthorityRequest, sessionId: String)? in
                guard let sessionId = normalized(request.agent.sessionId) else {
                    outcomes[request.surfaceId] = .rejected
                    return nil
                }
                return (request, sessionId)
            }
            guard !normalizedRequests.isEmpty else { continue }
            let legacyStampAtClaim = CmuxAgentSessionRegistry.LegacyStamp.read(
                path: stateURL.path
            )
            let providerClaims: [HibernatedResumeAuthorityClaim]
            let providerOutcomes: [UUID: HibernatedResumeAuthorityOutcome]
            do {
                let result = try registry(
                    provider: provider,
                    stateURL: stateURL,
                    busyTimeoutMilliseconds: busyBudget.remainingMilliseconds()
                ).withRecordRebindBatch { batch in
                    var accepted: [HibernatedResumeAuthorityClaim] = []
                    var transactionOutcomes: [UUID: HibernatedResumeAuthorityOutcome] = [:]
                    accepted.reserveCapacity(normalizedRequests.count)
                    for (request, sessionId) in normalizedRequests {
                        let activeSurfaceSlot = CmuxAgentSessionRegistry.ActiveSlotKey(
                            scope: .surface,
                            scopeID: request.surfaceId.uuidString
                        )
                        let result = try batch.patchRecordRebindingActiveSlots(
                            provider: provider,
                            sessionID: sessionId,
                            updatedAt: now,
                            previousSlots: [],
                            activeSlots: [activeSurfaceSlot],
                            requireExistingActiveSlots: true,
                            monotonicUpdatedAt: true,
                            shouldMutate: { record in
                                guard record["sessionState"] as? String
                                        == AgentSessionLifecycleState.hibernated.rawValue,
                                      record["restoreAuthority"] as? Bool != false,
                                      !hasCompletion(record),
                                      record["updatedAt"] is TimeInterval,
                                      recordBelongsToCurrentRuntime(record),
                                      let recordWorkspaceId = normalized(record["workspaceId"] as? String),
                                      let recordSurfaceId = normalized(record["surfaceId"] as? String) else {
                                    return false
                                }
                                return identifiersEqual(
                                    recordWorkspaceId,
                                    request.workspaceId.uuidString
                                ) && identifiersEqual(
                                    recordSurfaceId,
                                    request.surfaceId.uuidString
                                )
                            }
                        ) { record in
                            let effectiveNow = max(
                                now,
                                record["updatedAt"] as? TimeInterval ?? now
                            )
                            applyLifecycle(.restoring, to: &record, now: effectiveNow)
                            record.removeValue(forKey: "cmuxRestoreAdoptionId")
                        }
                        if result == .patched {
                            transactionOutcomes[request.surfaceId] = .acquired
                            accepted.append(HibernatedResumeAuthorityClaim(
                                request: request,
                                legacyStampAtClaim: legacyStampAtClaim
                            ))
                        } else {
                            transactionOutcomes[request.surfaceId] = .rejected
                        }
                    }
                    return (accepted, transactionOutcomes)
                }
                providerClaims = result.0
                providerOutcomes = result.1
            } catch {
                for request in providerRequests {
                    outcomes[request.surfaceId] = .unavailable
                }
                continue
            }
            outcomes.merge(providerOutcomes) { _, new in new }
            guard !providerClaims.isEmpty else { continue }
            Task(priority: .utility) {
                await Self.writeCoordinator.projectHibernatedResumesToLegacy(
                    using: self,
                    provider: provider,
                    stateURL: stateURL,
                    claims: providerClaims,
                    now: now
                )
            }
        }
        return outcomes
    }

    /// Waits for compatibility writers without retry sleeps. Darwin reports
    /// `NOTE_FUNLOCK` through kqueue when another process releases `flock`, and
    /// a pipe wakes the same kernel wait on task cancellation. The monotonic
    /// budget is shared with the following SQLite transaction.
    private func acquireLegacyReadLock(
        descriptor: Int32,
        mode: LegacyReadLockMode,
        busyBudget: MonotonicBusyBudget,
        waitWillBegin: @escaping @Sendable () -> Void,
        cancellationDescriptor: Int32?,
        cancellationCheck: @Sendable () -> Bool
    ) -> Bool {
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 { return true }
        guard errno == EWOULDBLOCK || errno == EAGAIN,
              mode == .wait,
              !cancellationCheck() else {
            return false
        }

        waitWillBegin()
        let queue = kqueue()
        guard queue >= 0 else { return false }
        defer { Darwin.close(queue) }

        var changes = [kevent64_s()]
        changes[0].ident = UInt64(descriptor)
        changes[0].filter = Int16(EVFILT_VNODE)
        changes[0].flags = UInt16(EV_ADD | EV_CLEAR)
        changes[0].fflags = UInt32(NOTE_FUNLOCK)
        if let cancellationDescriptor {
            changes.append(kevent64_s())
            changes[1].ident = UInt64(cancellationDescriptor)
            changes[1].filter = Int16(EVFILT_READ)
            changes[1].flags = UInt16(EV_ADD | EV_CLEAR)
        }
        let registrationResult = changes.withUnsafeBufferPointer { buffer in
            kevent64(queue, buffer.baseAddress, Int32(buffer.count), nil, 0, 0, nil)
        }
        guard registrationResult == 0 else { return false }

        while !cancellationCheck() {
            // Close the registration race: the owner may have unlocked between
            // the first flock attempt and installing NOTE_FUNLOCK.
            if flock(descriptor, LOCK_SH | LOCK_NB) == 0 { return true }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { return false }

            let remainingNanoseconds = busyBudget.remainingNanoseconds()
            guard remainingNanoseconds > 0 else { return false }
            var timeout = timespec(
                tv_sec: Int(remainingNanoseconds / 1_000_000_000),
                tv_nsec: Int(remainingNanoseconds % 1_000_000_000)
            )
            var event = kevent64_s()
            let eventCount = kevent64(queue, nil, 0, &event, 1, 0, &timeout)
            if eventCount == 0 { return false }
            if eventCount < 0 {
                guard errno == EINTR else { return false }
                continue
            }
            if event.filter == Int16(EVFILT_READ) { return false }
        }
        return false
    }

    private func adoptRestoredHibernationsHoldingLegacyReadLock(
        provider: String,
        stateURL: URL,
        requests: [RestoredHibernationAdoptionRequest],
        now: TimeInterval,
        busyBudget: MonotonicBusyBudget,
        legacyReadLockMode: LegacyReadLockMode,
        legacyReadLockWaitWillBegin: @escaping @Sendable () -> Void,
        legacyReadLockCancellationDescriptor: Int32?,
        cancellationCheck: @Sendable () -> Bool = { false }
    ) -> (
        adopted: [RestoredHibernationAdoptionRequest],
        outcomes: [UUID: RestoredHibernationAdoptionOutcome]
    ) {
        var initialOutcomes: [UUID: RestoredHibernationAdoptionOutcome] = [:]
        let normalizedRequests = requests.compactMap { request -> (RestoredHibernationAdoptionRequest, String)? in
            guard let sessionId = normalized(request.agent.sessionId) else {
                initialOutcomes[request.surfaceId] = .rejected
                return nil
            }
            return (request, sessionId)
        }
        guard !normalizedRequests.isEmpty else { return ([], initialOutcomes) }
        func unavailableResult() -> (
            adopted: [RestoredHibernationAdoptionRequest],
            outcomes: [UUID: RestoredHibernationAdoptionOutcome]
        ) {
            var outcomes = initialOutcomes
            for (request, _) in normalizedRequests {
                outcomes[request.surfaceId] = .unavailable
            }
            return ([], outcomes)
        }
        let descriptor = open(
            stateURL.path + ".lock",
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { return unavailableResult() }
        defer { Darwin.close(descriptor) }
        guard acquireLegacyReadLock(
            descriptor: descriptor,
            mode: legacyReadLockMode,
            busyBudget: busyBudget,
            waitWillBegin: legacyReadLockWaitWillBegin,
            cancellationDescriptor: legacyReadLockCancellationDescriptor,
            cancellationCheck: cancellationCheck
        ) else { return unavailableResult() }
        defer { _ = flock(descriptor, LOCK_UN) }
        guard !cancellationCheck() else { return unavailableResult() }

        let registry = registry(
            provider: provider,
            stateURL: stateURL,
            busyTimeoutMilliseconds: busyBudget.remainingMilliseconds()
        )
        guard let ownerPreflights = restoredHibernationOwnerPreflights(
            provider: provider,
            stateURL: stateURL,
            normalizedRequests: normalizedRequests,
            registry: registry
        ) else {
            return unavailableResult()
        }
        do {
            return try registry.withLegacySourceRebindBatch(
                provider: provider,
                legacyURL: stateURL
            ) { batch in
                if cancellationCheck() { throw CancellationError() }
                var adopted: [RestoredHibernationAdoptionRequest] = []
                var outcomes = initialOutcomes
                adopted.reserveCapacity(normalizedRequests.count)
                for (request, sessionId) in normalizedRequests {
                    if cancellationCheck() { throw CancellationError() }
                    let previousSurfaceSlot = CmuxAgentSessionRegistry.ActiveSlotKey(
                        scope: .surface,
                        scopeID: request.previousSurfaceId.uuidString
                    )
                    let activeSurfaceSlot = CmuxAgentSessionRegistry.ActiveSlotKey(
                        scope: .surface,
                        scopeID: request.surfaceId.uuidString
                    )
                    let previousSurfaceOwner = try batch.activeSlotSessionID(
                        provider: provider,
                        key: previousSurfaceSlot
                    )
                    let activeSurfaceOwner = try batch.activeSlotSessionID(
                        provider: provider,
                        key: activeSurfaceSlot
                    )
                    let previousWorkspaceSlot = request.previousWorkspaceId.map {
                        CmuxAgentSessionRegistry.ActiveSlotKey(
                            scope: .workspace,
                            scopeID: $0.uuidString
                        )
                    }
                    let rebindWorkspaceActiveSlot = try previousWorkspaceSlot.map {
                        try batch.activeSlotSessionID(provider: provider, key: $0) == sessionId
                    } ?? false
                    var previousSlots = [previousSurfaceSlot]
                    var activeSlots = [activeSurfaceSlot]
                    if let previousWorkspaceSlot, rebindWorkspaceActiveSlot {
                        previousSlots.append(previousWorkspaceSlot)
                        activeSlots.append(
                            CmuxAgentSessionRegistry.ActiveSlotKey(
                                scope: .workspace,
                                scopeID: request.workspaceId.uuidString
                            )
                        )
                    }
                    let result = try batch.patchRecordRebindingActiveSlots(
                        provider: provider,
                        sessionID: sessionId,
                        updatedAt: now,
                        previousSlots: previousSlots,
                        activeSlots: activeSlots,
                        monotonicUpdatedAt: true,
                        shouldMutate: { record in
                            guard restoredRecordCanBeAdopted(
                                record,
                                previousWorkspaceId: request.previousWorkspaceId?.uuidString,
                                previousSurfaceId: request.previousSurfaceId.uuidString,
                                workspaceId: request.workspaceId.uuidString,
                                surfaceId: request.surfaceId.uuidString
                            ),
                            let ownerPreflight = ownerPreflights[sessionId],
                            !ownerPreflight.hasProvablyLiveForeignRuntime,
                            restoredHibernationRecordFingerprint(record)
                                == ownerPreflight.recordFingerprint,
                            let recordWorkspaceId = normalized(record["workspaceId"] as? String),
                            let recordSurfaceId = normalized(record["surfaceId"] as? String) else {
                                return false
                            }
                            // A record still on its persisted binding needs the
                            // old singular surface slot. An idempotent repeat
                            // after a successful transfer instead needs the new
                            // slot. Workspace slots differ: sibling panels can
                            // share one workspace, so only its actual owner
                            // transfers that optional slot above.
                            let alreadyAdopted = identifiersEqual(
                                recordWorkspaceId,
                                request.workspaceId.uuidString
                            ) && identifiersEqual(
                                recordSurfaceId,
                                request.surfaceId.uuidString
                            )
                            return alreadyAdopted
                                ? activeSurfaceOwner == sessionId
                                : previousSurfaceOwner == sessionId
                        }
                    ) { record in
                        let effectiveNow = max(now, record["updatedAt"] as? TimeInterval ?? now)
                        applyRestoredHibernation(
                            to: &record,
                            workspaceId: request.workspaceId.uuidString,
                            surfaceId: request.surfaceId.uuidString,
                            now: effectiveNow
                        )
                        record["cmuxRestoreAdoptionId"] = request.adoptionId.uuidString
                    }
                    if result == .patched {
                        var adoptedRequest = request
                        adoptedRequest.rebindWorkspaceActiveSlot = rebindWorkspaceActiveSlot
                        adopted.append(adoptedRequest)
                        outcomes[request.surfaceId] = .adopted
                    } else {
                        outcomes[request.surfaceId] = .rejected
                    }
                }
                return (adopted, outcomes)
            }
        } catch {
            return unavailableResult()
        }
    }

    func projectRestoredHibernationsToLegacy(
        provider: String,
        stateURL: URL,
        requests: [RestoredHibernationAdoptionRequest],
        now: TimeInterval
    ) {
        projectCanonicalLegacy(provider: provider, stateURL: stateURL)
    }

    private func projectHibernatedResumesToLegacy(
        provider: String,
        stateURL: URL,
        claims: [HibernatedResumeAuthorityClaim],
        now: TimeInterval
    ) {
        projectCanonicalLegacy(provider: provider, stateURL: stateURL)
    }

    func projectEstablishedHibernationToLegacy(
        provider: String,
        stateURL: URL,
        request: HibernatedResumeAuthorityRequest,
        legacyStampAtClaim: CmuxAgentSessionRegistry.LegacyStamp?,
        now: TimeInterval
    ) {
        projectCanonicalLegacy(provider: provider, stateURL: stateURL)
    }

    private func applyCompletion(to record: inout [String: Any], now: TimeInterval) {
        record["completedAt"] = now
        record["updatedAt"] = now
        record["runtimeStatus"] = "idle"
        record["agentLifecycle"] = "idle"
        if record["foregroundState"] as? String != "interrupted" {
            record["foregroundState"] = "completed"
        }
        record["attentionState"] = "none"
        record["sessionState"] = "ended"
        record["restoreAuthority"] = false
        record.removeValue(forKey: "activeRunId")
        record["runs"] = completeRuns(record["runs"], now: now)
        record["workloads"] = cancelWorkloads(record["workloads"], now: now)
    }

    private func applyLifecycle(
        _ lifecycle: AgentSessionLifecycleState,
        to record: inout [String: Any],
        now: TimeInterval
    ) {
        record["sessionState"] = lifecycle.rawValue
        record["updatedAt"] = now
        if let runtime = runtimePayload() {
            record["cmuxRuntime"] = runtime
            record["runs"] = assigningRuntime(
                runtime,
                to: record["runs"],
                activeRunId: record["activeRunId"] as? String
            )
        }
    }

    private func applyRestoredHibernation(
        to record: inout [String: Any],
        workspaceId: String,
        surfaceId: String,
        now: TimeInterval
    ) {
        applyLifecycle(.hibernated, to: &record, now: now)
        record["workspaceId"] = workspaceId
        record["surfaceId"] = surfaceId
    }

    private func restoredRecordCanBeAdopted(
        _ record: [String: Any],
        previousWorkspaceId: String?,
        previousSurfaceId: String,
        workspaceId: String,
        surfaceId: String
    ) -> Bool {
        guard record["sessionState"] as? String == AgentSessionLifecycleState.hibernated.rawValue,
              record["restoreAuthority"] as? Bool != false,
              !hasCompletion(record),
              record["updatedAt"] is TimeInterval,
              let recordWorkspaceId = normalized(record["workspaceId"] as? String),
              let recordSurfaceId = normalized(record["surfaceId"] as? String) else {
            return false
        }
        let alreadyAdopted = identifiersEqual(recordWorkspaceId, workspaceId)
            && identifiersEqual(recordSurfaceId, surfaceId)
        let matchesPreviousWorkspace = previousWorkspaceId.map {
            identifiersEqual(recordWorkspaceId, $0)
        } ?? true
        let matchesPreviousBinding = matchesPreviousWorkspace
            && identifiersEqual(recordSurfaceId, previousSurfaceId)
        return alreadyAdopted || matchesPreviousBinding
    }

    private func preparedRegistry(
        provider: String,
        stateURL: URL
    ) -> CmuxAgentSessionRegistry {
        let registry = registry(provider: provider, stateURL: stateURL)
        _ = try? registry.refreshLegacySources(
            [.init(provider: provider, url: stateURL)]
        )
        return registry
    }

    private func projectCanonicalLegacy(provider: String, stateURL: URL) {
        let registry = registry(
            provider: provider,
            stateURL: stateURL,
            busyTimeoutMilliseconds: 2_000
        )
        do {
            let status = try registry.hookProjectionStatus(provider: provider)
            try registry.projectHookLegacyStore(
                provider: provider,
                to: stateURL,
                including: status.revision
            )
        } catch {
            NSLog(
                "[AgentHookSessionStateWriter] canonical projection failed provider=%@ error=%@",
                provider,
                String(describing: error)
            )
        }
    }

    private func registry(
        provider: String,
        stateURL: URL,
        busyTimeoutMilliseconds: Int32 = 100
    ) -> CmuxAgentSessionRegistry {
        let registryURL: URL
        if let explicit = environment["CMUX_AGENT_SESSION_REGISTRY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            registryURL = URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath)
        } else {
            registryURL = stateURL.deletingLastPathComponent()
                .appendingPathComponent(CmuxAgentSessionRegistry.filename, isDirectory: false)
        }
        return CmuxAgentSessionRegistry(
            url: registryURL,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds
        )
    }

    private func completeRuns(_ value: Any?, now: TimeInterval) -> [[String: Any]] {
        guard let runs = value as? [[String: Any]] else { return [] }
        return runs.map { run in
            var run = run
            if run["endedAt"] == nil {
                run["endedAt"] = now
                run["updatedAt"] = now
                run["restoreAuthority"] = false
            }
            return run
        }
    }

    private func runtimePayload() -> [String: Any]? {
        guard let id = environment["CMUX_RUNTIME_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        var payload: [String: Any] = ["id": id]
        if let socketPath = environment["CMUX_SOCKET_PATH"], !socketPath.isEmpty {
            payload["socketPath"] = socketPath
        }
        if let bundleIdentifier = environment["CMUX_BUNDLE_ID"], !bundleIdentifier.isEmpty {
            payload["bundleIdentifier"] = bundleIdentifier
        }
        return payload
    }

    /// Resume authority belongs to a concrete cmux process, not only to the
    /// stable workspace/surface UUIDs that session restore preserves. Both the
    /// root record and its active run must still name this process before cmux
    /// can queue provider resume input.
    private func recordBelongsToCurrentRuntime(_ record: [String: Any]) -> Bool {
        guard let currentRuntimeId = normalized(environment["CMUX_RUNTIME_ID"]),
              let runtime = record["cmuxRuntime"] as? [String: Any],
              normalized(runtime["id"] as? String) == currentRuntimeId else {
            return false
        }
        guard let activeRunId = normalized(record["activeRunId"] as? String) else {
            return true
        }
        guard let runs = record["runs"] as? [[String: Any]],
              let activeRun = runs.first(where: {
                  normalized($0["runId"] as? String) == activeRunId
              }),
              let activeRunRuntime = activeRun["cmuxRuntime"] as? [String: Any],
              normalized(activeRunRuntime["id"] as? String) == currentRuntimeId else {
            return false
        }
        return true
    }

    /// Reads and probes the prospective owner before opening the SQLite writer
    /// transaction. The transaction compares the exact canonicalized record,
    /// turning this preflight into a CAS instead of holding a database lock
    /// across filesystem and socket I/O.
    private func restoredHibernationOwnerPreflights(
        provider: String,
        stateURL: URL,
        normalizedRequests: [(RestoredHibernationAdoptionRequest, String)],
        registry: CmuxAgentSessionRegistry
    ) -> [String: RestoredHibernationOwnerPreflight]? {
        let sessionIds = Set(normalizedRequests.map(\.1))
        guard let canonicalRecords = try? registry.records(
            provider: provider,
            sessionIDs: sessionIds
        ) else { return nil }
        let canonicalBySessionId = Dictionary(
            canonicalRecords.map { ($0.sessionID, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )

        let legacyStamp = CmuxAgentSessionRegistry.LegacyStamp.read(path: stateURL.path)
        let legacyWillRefresh: Bool
        if let legacyStamp {
            guard let canSkip = try? registry.legacySourceCanBeSkippedForCanonicalRebind(
                provider: provider,
                stamp: legacyStamp
            ) else { return nil }
            legacyWillRefresh = !canSkip
        } else {
            legacyWillRefresh = false
        }
        let legacySessions: [String: Any] = {
            guard legacyWillRefresh,
                  let data = try? registry.readHookLegacySourceData(at: stateURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            return root["sessions"] as? [String: Any] ?? [:]
        }()
        var result: [String: RestoredHibernationOwnerPreflight] = [:]
        var foreignSocketLiveness: [String: Bool] = [:]
        var currentSocketState: (
            activePath: String,
            pathOwnedByCurrentListener: Bool
        )?
        result.reserveCapacity(sessionIds.count)
        for sessionId in sessionIds {
            let canonical = canonicalBySessionId[sessionId]
            let record: [String: Any]?
            if let canonical, canonical.writerGeneration > 0 {
                record = try? JSONSerialization.jsonObject(with: canonical.json) as? [String: Any]
            } else if legacyWillRefresh,
                      let legacyRecord = legacySessions[sessionId] as? [String: Any] {
                record = legacyRecord
            } else if let canonical {
                record = try? JSONSerialization.jsonObject(with: canonical.json) as? [String: Any]
            } else {
                record = nil
            }
            guard let record,
                  let fingerprint = restoredHibernationRecordFingerprint(record) else {
                return nil
            }
            result[sessionId] = RestoredHibernationOwnerPreflight(
                recordFingerprint: fingerprint,
                hasProvablyLiveForeignRuntime: recordHasProvablyLiveForeignRuntime(
                    record,
                    currentSocketState: &currentSocketState,
                    foreignSocketLiveness: &foreignSocketLiveness
                )
            )
        }
        return result
    }

    private func restoredHibernationRecordFingerprint(_ record: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(record) else { return nil }
        return try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    }

    /// Stable workspace and surface UUIDs survive an app restart, so matching
    /// those identifiers alone cannot distinguish a stale saved owner from a
    /// second cmux process that is still serving the same restored binding.
    /// Only a successful non-blocking connection is treated as proof that the
    /// foreign runtime remains live. Missing, refused, or legacy socket metadata
    /// stays eligible for normal app-restart adoption.
    private func recordHasProvablyLiveForeignRuntime(
        _ record: [String: Any],
        currentSocketState: inout (
            activePath: String,
            pathOwnedByCurrentListener: Bool
        )?,
        foreignSocketLiveness: inout [String: Bool]
    ) -> Bool {
        let currentRuntimeId = normalized(environment["CMUX_RUNTIME_ID"])
        var runtimes: [[String: Any]] = []
        if let runtime = record["cmuxRuntime"] as? [String: Any] {
            runtimes.append(runtime)
        }
        if let activeRunId = normalized(record["activeRunId"] as? String),
           let runs = record["runs"] as? [[String: Any]],
           let activeRun = runs.first(where: {
               normalized($0["runId"] as? String) == activeRunId
           }),
           let runtime = activeRun["cmuxRuntime"] as? [String: Any] {
            runtimes.append(runtime)
        }

        var probedSocketPaths: Set<String> = []
        let socketTransport = SocketTransport()
        for runtime in runtimes {
            guard let runtimeId = normalized(runtime["id"] as? String),
                  runtimeId != currentRuntimeId,
                  let socketPath = normalized(runtime["socketPath"] as? String),
                  probedSocketPaths.insert(socketPath).inserted else {
                continue
            }
            if currentSocketState == nil {
                let preferredSocketPath = SocketControlSettings.socketPath(
                    environment: environment,
                    bundleIdentifier: normalized(environment["CMUX_BUNDLE_ID"])
                        ?? Bundle.main.bundleIdentifier
                )
                currentSocketState = currentSocketStateResolver(preferredSocketPath)
            }
            if let currentSocketState,
               currentSocketState.pathOwnedByCurrentListener,
               SocketControlSettings.pathsMatch(socketPath, currentSocketState.activePath) {
                continue
            }
            let isLive: Bool
            if let cached = foreignSocketLiveness[socketPath] {
                isLive = cached
            } else {
                isLive = socketTransport.pathAcceptsConnections(socketPath)
                foreignSocketLiveness[socketPath] = isLive
            }
            if isLive {
                return true
            }
        }
        return false
    }

    private func assigningRuntime(
        _ runtime: [String: Any],
        to value: Any?,
        activeRunId: String?
    ) -> [[String: Any]] {
        guard let runs = value as? [[String: Any]], let activeRunId else { return value as? [[String: Any]] ?? [] }
        return runs.map { run in
            guard run["runId"] as? String == activeRunId else { return run }
            var updated = run
            updated["cmuxRuntime"] = runtime
            return updated
        }
    }

    private func cancelWorkloads(_ value: Any?, now: TimeInterval) -> [[String: Any]] {
        guard let workloads = value as? [[String: Any]] else { return [] }
        let activePhases: Set<String> = ["queued", "running", "watching", "waiting"]
        return workloads.map { workload in
            var workload = workload
            if let phase = workload["phase"] as? String, activePhases.contains(phase) {
                workload["phase"] = "cancelled"
                workload["updatedAt"] = now
                workload["endedAt"] = now
                workload["endReason"] = "root_exited"
            }
            return workload
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func identifiersEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func hasCompletion(_ record: [String: Any]) -> Bool {
        guard let completedAt = record["completedAt"] else { return false }
        return !(completedAt is NSNull)
    }

}
