internal import CmuxTerminalBackend
internal import Foundation

/// All authority needed to reject a delayed visible-window plan.
nonisolated struct BackendOnlyProjectionRuntimeFence: Equatable, Sendable {
    /// Monotonic generation assigned by the Swift connection owner.
    ///
    /// Backend authority UUIDs identify lifetimes but cannot order two socket
    /// connections. This generation makes a delayed plan from an older
    /// connection comparable with the current one.
    let connectionGeneration: UInt64
    let authority: BackendAuthority
    let topologyRevision: UInt64
    let logicalPresentationID: UUID
    let projectionGeneration: UInt64
}

nonisolated enum BackendOnlyProjectionRuntimeReconcilerError: Error, Equatable, Sendable {
    case invalidFence
    case planLogicalPresentationMismatch
    case logicalPresentationMismatch
    case authorityMismatch
    case sessionObjectMismatch
    case staleFence
    case conflictingPlanForFence
    case duplicateFenceInFlight
    case requestGenerationExhausted
    case visibleSlotLimitExceeded(actual: Int, maximum: Int)
    case duplicateSlot(BackendOnlyProjectionSlotID)
    case invalidSlotIdentity(BackendOnlyProjectionSlotID)
    case layoutSlotSetMismatch
    case activePaneMismatch
    case runtimeConstructionFailed(slotID: BackendOnlyProjectionSlotID)
}

nonisolated enum BackendOnlyProjectionRuntimeReconcileResult: Equatable, Sendable {
    case unchanged
    case applied(created: Int, reused: Int, retired: Int)
    case superseded
}

@MainActor
struct BackendOnlyProjectionRuntimeSlot {
    let descriptor: BackendOnlyProjectionPaneDescriptor
    let runtime: (any BackendOnlyHostRuntimeLifecycle)?

    var slotID: BackendOnlyProjectionSlotID { descriptor.slotID }
}

/// One immutable, all-or-nothing visible runtime publication.
@MainActor
struct BackendOnlyProjectionRuntimeSnapshot {
    let fence: BackendOnlyProjectionRuntimeFence
    let plan: BackendOnlyProjectionPlan
    let slots: [BackendOnlyProjectionRuntimeSlot]
    let activeSlotID: BackendOnlyProjectionSlotID
}

typealias BackendOnlyProjectionRuntimeFactory = @MainActor (
    BackendCanonicalSession,
    BackendOnlyTerminalSelection
) async throws -> any BackendOnlyHostRuntimeLifecycle

/// Materializes the terminal subset of one immutable split projection.
///
/// A single drain owns all factory and retirement suspensions. At most one
/// newer plan waits behind it, so rapid topology changes cannot create an
/// unbounded queue of runtime graphs. Candidates are constructed in canonical
/// leaf order before publication. Any failure retires only those candidates
/// and leaves the previously published graph untouched.
@MainActor
final class BackendOnlyProjectionRuntimeReconciler {
    static let maximumVisibleSlotCount = 256

    private struct ManagedRuntime {
        let session: BackendCanonicalSession
        let lifecycle: any BackendOnlyHostRuntimeLifecycle
    }

    private struct Request {
        let identifier: UInt64
        let session: BackendCanonicalSession
        let fence: BackendOnlyProjectionRuntimeFence
        let plan: BackendOnlyProjectionPlan
    }

    private struct Admission {
        let identifier: UInt64
        let session: BackendCanonicalSession
        let fence: BackendOnlyProjectionRuntimeFence
        let plan: BackendOnlyProjectionPlan
    }

    private typealias Continuation = CheckedContinuation<
        BackendOnlyProjectionRuntimeReconcileResult,
        any Error
    >

    private let factory: BackendOnlyProjectionRuntimeFactory
    private var managed: [BackendOnlyProjectionSlotID: ManagedRuntime] = [:]
    private var managedOrder: [BackendOnlyProjectionSlotID] = []
    private var nextRequestIdentifier: UInt64 = 1
    private var pendingRequest: Request?
    private var continuations: [UInt64: Continuation] = [:]
    private var drainTask: Task<Void, Never>?
    private var newestAdmission: Admission?
    private var publishedAdmission: Admission?
    private var logicalPresentationID: UUID?

    private(set) var snapshot: BackendOnlyProjectionRuntimeSnapshot?

    init(factory: BackendOnlyProjectionRuntimeFactory? = nil) {
        self.factory = factory ?? { session, selection in
            BackendOnlyTerminalRuntime(session: session, selection: selection)
        }
    }

    func apply(
        session: BackendCanonicalSession,
        fence: BackendOnlyProjectionRuntimeFence,
        plan: BackendOnlyProjectionPlan
    ) async throws -> BackendOnlyProjectionRuntimeReconcileResult {
        try validate(plan: plan, fence: fence)

        if let current = newestAdmission {
            switch try compare(
                incomingFence: fence,
                incomingSession: session,
                with: current
            ) {
            case .older:
                throw BackendOnlyProjectionRuntimeReconcilerError.staleFence
            case .same:
                guard plan == current.plan else {
                    throw BackendOnlyProjectionRuntimeReconcilerError
                        .conflictingPlanForFence
                }
                if publishedAdmission?.identifier == current.identifier,
                   drainTask == nil,
                   pendingRequest == nil
                {
                    return .unchanged
                }
                throw BackendOnlyProjectionRuntimeReconcilerError
                    .duplicateFenceInFlight
            case .newer:
                break
            }
        }

        guard nextRequestIdentifier != UInt64.max else {
            throw BackendOnlyProjectionRuntimeReconcilerError
                .requestGenerationExhausted
        }
        let identifier = nextRequestIdentifier
        nextRequestIdentifier += 1
        let request = Request(
            identifier: identifier,
            session: session,
            fence: fence,
            plan: plan
        )
        newestAdmission = Admission(
            identifier: identifier,
            session: session,
            fence: fence,
            plan: plan
        )

        return try await withCheckedThrowingContinuation {
            (continuation: Continuation) in
            if let replaced = pendingRequest {
                continuations.removeValue(forKey: replaced.identifier)?
                    .resume(returning: .superseded)
            }
            pendingRequest = request
            continuations[identifier] = continuation
            startDrainIfNeeded()
        }
    }

    private enum FenceOrder {
        case older
        case same
        case newer
    }

    private func compare(
        incomingFence: BackendOnlyProjectionRuntimeFence,
        incomingSession: BackendCanonicalSession,
        with current: Admission
    ) throws -> FenceOrder {
        if incomingFence.connectionGeneration < current.fence.connectionGeneration {
            return .older
        }
        if incomingFence.connectionGeneration > current.fence.connectionGeneration {
            return .newer
        }
        guard incomingFence.authority == current.fence.authority else {
            throw BackendOnlyProjectionRuntimeReconcilerError.authorityMismatch
        }
        guard incomingFence.logicalPresentationID
                == current.fence.logicalPresentationID
        else {
            throw BackendOnlyProjectionRuntimeReconcilerError
                .logicalPresentationMismatch
        }
        guard incomingSession === current.session else {
            throw BackendOnlyProjectionRuntimeReconcilerError
                .sessionObjectMismatch
        }
        guard incomingFence.topologyRevision >= current.fence.topologyRevision,
              incomingFence.projectionGeneration
                >= current.fence.projectionGeneration
        else {
            return .older
        }
        if incomingFence.topologyRevision == current.fence.topologyRevision,
           incomingFence.projectionGeneration
            == current.fence.projectionGeneration
        {
            return .same
        }
        return .newer
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drain()
        }
    }

    private func drain() async {
        while !Task.isCancelled, let request = takePendingRequest() {
            do {
                let result = try await reconcile(request)
                continuations.removeValue(forKey: request.identifier)?
                    .resume(returning: result)
            } catch {
                rollBackAdmissionAfterFailure(request)
                continuations.removeValue(forKey: request.identifier)?
                    .resume(throwing: error)
            }
        }
        drainTask = nil
        if pendingRequest != nil {
            startDrainIfNeeded()
        }
    }

    private func takePendingRequest() -> Request? {
        let request = pendingRequest
        pendingRequest = nil
        return request
    }

    private func rollBackAdmissionAfterFailure(_ request: Request) {
        guard newestAdmission?.identifier == request.identifier else { return }
        newestAdmission = publishedAdmission
    }

    private func reconcile(
        _ request: Request
    ) async throws -> BackendOnlyProjectionRuntimeReconcileResult {
        var nextManaged: [BackendOnlyProjectionSlotID: ManagedRuntime] = [:]
        nextManaged.reserveCapacity(request.plan.panes.count)
        var candidates: [ManagedRuntime] = []
        candidates.reserveCapacity(request.plan.panes.count)
        var reusedCount = 0

        for descriptor in request.plan.panes {
            guard case .terminal(let selection) = descriptor.content else {
                continue
            }
            if let current = managed[descriptor.slotID],
               current.session === request.session,
               current.lifecycle.selection == selection
            {
                nextManaged[descriptor.slotID] = current
                reusedCount += 1
                continue
            }

            let lifecycle: any BackendOnlyHostRuntimeLifecycle
            do {
                lifecycle = try await factory(request.session, selection)
            } catch {
                await retireCandidates(candidates)
                throw BackendOnlyProjectionRuntimeReconcilerError
                    .runtimeConstructionFailed(slotID: descriptor.slotID)
            }
            let candidate = ManagedRuntime(
                session: request.session,
                lifecycle: lifecycle
            )
            candidates.append(candidate)
            nextManaged[descriptor.slotID] = candidate

            guard isNewest(request) else {
                await retireCandidates(candidates)
                return .superseded
            }
        }

        guard isNewest(request) else {
            await retireCandidates(candidates)
            return .superseded
        }

        let retainedRuntimeIDs = Set(
            nextManaged.values.map { ObjectIdentifier($0.lifecycle) }
        )
        let obsolete = managedOrder.compactMap { slotID -> ManagedRuntime? in
            guard let current = managed[slotID],
                  !retainedRuntimeIDs.contains(ObjectIdentifier(current.lifecycle))
            else { return nil }
            return current
        }

        if !obsolete.isEmpty {
            // Once construction is known-good, remove the stale graph before
            // any asynchronous retirement can let AppKit render it again.
            snapshot = nil
            publishedAdmission = nil
            let obsoleteIDs = Set(
                obsolete.map { ObjectIdentifier($0.lifecycle) }
            )
            for slotID in managedOrder {
                guard let current = managed[slotID],
                      obsoleteIDs.contains(ObjectIdentifier(current.lifecycle))
                else { continue }
                managed.removeValue(forKey: slotID)
            }
            managedOrder.removeAll { managed[$0] == nil }
            var retired: Set<ObjectIdentifier> = []
            for value in obsolete {
                let identity = ObjectIdentifier(value.lifecycle)
                guard retired.insert(identity).inserted else { continue }
                await value.lifecycle.shutdown()
                // A newer plan may arrive at any retirement suspension. Every
                // old runtime still retires exactly once, then the guard below
                // discards candidates and starts from that newest whole plan.
                _ = isNewest(request)
            }
        }

        guard isNewest(request) else {
            await retireCandidates(candidates)
            return .superseded
        }

        let slots = request.plan.panes.map { descriptor in
            BackendOnlyProjectionRuntimeSlot(
                descriptor: descriptor,
                runtime: nextManaged[descriptor.slotID]?.lifecycle
            )
        }
        let activeSlotID = request.plan.panes.first {
            $0.paneID == request.plan.activePaneID
        }!.slotID

        managed = nextManaged
        managedOrder = request.plan.panes.compactMap { descriptor in
            nextManaged[descriptor.slotID] == nil ? nil : descriptor.slotID
        }
        snapshot = BackendOnlyProjectionRuntimeSnapshot(
            fence: request.fence,
            plan: request.plan,
            slots: slots,
            activeSlotID: activeSlotID
        )
        let admission = Admission(
            identifier: request.identifier,
            session: request.session,
            fence: request.fence,
            plan: request.plan
        )
        publishedAdmission = admission
        newestAdmission = admission
        return .applied(
            created: candidates.count,
            reused: reusedCount,
            retired: obsolete.count
        )
    }

    private func isNewest(_ request: Request) -> Bool {
        newestAdmission?.identifier == request.identifier
    }

    private func retireCandidates(_ values: [ManagedRuntime]) async {
        var retired: Set<ObjectIdentifier> = []
        for value in values {
            let identity = ObjectIdentifier(value.lifecycle)
            guard retired.insert(identity).inserted else { continue }
            await value.lifecycle.shutdown()
        }
    }

    private func validate(
        plan: BackendOnlyProjectionPlan,
        fence: BackendOnlyProjectionRuntimeFence
    ) throws {
        guard fence.connectionGeneration > 0,
              fence.topologyRevision > 0,
              fence.projectionGeneration > 0,
              !Self.isNilUUID(fence.logicalPresentationID),
              !Self.isNilUUID(fence.authority.daemonInstanceID.rawValue),
              !Self.isNilUUID(fence.authority.sessionID.rawValue)
        else {
            throw BackendOnlyProjectionRuntimeReconcilerError.invalidFence
        }
        guard plan.logicalPresentationID == fence.logicalPresentationID else {
            throw BackendOnlyProjectionRuntimeReconcilerError
                .planLogicalPresentationMismatch
        }
        if let logicalPresentationID,
           logicalPresentationID != fence.logicalPresentationID
        {
            throw BackendOnlyProjectionRuntimeReconcilerError
                .logicalPresentationMismatch
        }
        guard plan.panes.count <= Self.maximumVisibleSlotCount else {
            throw BackendOnlyProjectionRuntimeReconcilerError
                .visibleSlotLimitExceeded(
                    actual: plan.panes.count,
                    maximum: Self.maximumVisibleSlotCount
                )
        }

        var descriptorSlots: Set<BackendOnlyProjectionSlotID> = []
        descriptorSlots.reserveCapacity(plan.panes.count)
        for descriptor in plan.panes {
            guard descriptorSlots.insert(descriptor.slotID).inserted else {
                throw BackendOnlyProjectionRuntimeReconcilerError
                    .duplicateSlot(descriptor.slotID)
            }
            guard descriptor.slotID.logicalPresentationID
                    == plan.logicalPresentationID,
                  descriptor.slotID.workspaceID == plan.workspaceID,
                  descriptor.slotID.screenID == plan.screenID,
                  descriptor.slotID.paneID == descriptor.paneID
            else {
                throw BackendOnlyProjectionRuntimeReconcilerError
                    .invalidSlotIdentity(descriptor.slotID)
            }
            if case .terminal(let selection) = descriptor.content {
                guard selection.workspaceID == plan.workspaceID,
                      selection.screenID == plan.screenID,
                      selection.paneID == descriptor.paneID
                else {
                    throw BackendOnlyProjectionRuntimeReconcilerError
                        .invalidSlotIdentity(descriptor.slotID)
                }
            }
        }

        let layoutSlots = Self.layoutLeafSlots(plan.layout)
        guard layoutSlots == plan.panes.map(\.slotID),
              Set(layoutSlots) == descriptorSlots
        else {
            throw BackendOnlyProjectionRuntimeReconcilerError
                .layoutSlotSetMismatch
        }
        guard plan.panes.filter(\.isActive).count == 1,
              plan.panes.first(where: { $0.isActive })?.paneID
                == plan.activePaneID
        else {
            throw BackendOnlyProjectionRuntimeReconcilerError.activePaneMismatch
        }
        logicalPresentationID = fence.logicalPresentationID
    }

    private static func layoutLeafSlots(
        _ layout: BackendOnlyProjectionLayout
    ) -> [BackendOnlyProjectionSlotID] {
        var result: [BackendOnlyProjectionSlotID] = []
        var stack = [layout]
        while let node = stack.popLast() {
            switch node {
            case .pane(let slotID):
                result.append(slotID)
            case .split(_, _, let first, let second):
                stack.append(second)
                stack.append(first)
            }
        }
        return result
    }

    private static func isNilUUID(_ value: UUID) -> Bool {
        value == UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        )
    }
}
