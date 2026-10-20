import CmuxAuthRuntime
import Foundation

/// Keeps owner observation independent of startup work and retains original-record reconciliation authority.
@MainActor
package final class CloudAuthoritySession {
    private let capability: CloudObservedAuthority
    private let initial: @Sendable () async throws -> CloudTeamScope.Binding
    private let current: @MainActor @Sendable (AuthenticatedSessionIdentity) -> Bool
    private let lost: @MainActor @Sendable (AuthenticatedSessionIdentity, Bool) -> Void
    private let make: @Sendable (CloudTeamScope.Snapshot) -> CloudAuthorityObservation
    private var original: (identity: AuthenticatedSessionIdentity, scope: CloudTeamScope.Snapshot)?
    private var binding: (identity: AuthenticatedSessionIdentity, scope: CloudTeamScope.Binding)?
    private var registration: AuthenticatedSessionIdentity?
    private var reselect = false
    private var cycle: UUID?
    private var admitted = false
    private var observation: CloudAuthorityObservation?
    private var receiver: Task<Void, Never>?
    private var opening: Task<Void, Error>?
    private var readiness: AsyncStream<Bool>.Continuation?
    private var draining: Task<Void, Never>?

    package init(capability: CloudObservedAuthority, initial: @escaping @Sendable () async throws -> CloudTeamScope.Binding,
                 current: @escaping @MainActor @Sendable (AuthenticatedSessionIdentity) -> Bool,
                 lost: @escaping @MainActor @Sendable (AuthenticatedSessionIdentity, Bool) -> Void,
                 make: @escaping @Sendable (CloudTeamScope.Snapshot) -> CloudAuthorityObservation) {
        self.capability = capability; self.initial = initial; self.current = current; self.lost = lost; self.make = make
    }

    /// The lifecycle owns this startup call. Feed events keep fencing admission while that caller awaits HTTP.
    package func start(_ identity: AuthenticatedSessionIdentity) async throws {
        await draining?.value
        guard cycle == nil, current(identity) else { throw CloudTeamScope.Failure.changed }
        let ticket = UUID(), ready = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        cycle = ticket; admitted = false; readiness = ready.continuation
        do {
            let scope: CloudTeamScope.Snapshot
            if let original, original.identity == identity {
                scope = try await (reselect ? original.scope.reselectAuthority() : original.scope.refreshAuthority())
            } else {
                if binding?.identity != identity {
                    let scope = try await initial()
                    try check(ticket, identity)
                    binding = (identity, scope)
                }
                guard let binding else { throw CloudTeamScope.Failure.changed }
                scope = try await (reselect ? binding.scope.reselect() : binding.scope.snapshot())
            }
            try check(ticket, identity)
            original = (identity, scope); reselect = false
            let observation = make(scope)
            self.observation = observation
            // task-owner: receiver; fence cancels and joins it separately from the lifecycle's startup worker.
            receiver = Task { [weak self] in
                for await state in observation.events {
                    guard !Task.isCancelled, let self else { return }
                    self.receive(state, scope: scope, ticket: ticket, identity: identity)
                }
            }
            // task-owner: opening; fence cancels and joins the original lease load even if HTTP ignores cancellation.
            let opening = Task { try await observation.start() }
            self.opening = opening
            try await opening.value
            try check(ticket, identity)
            var iterator = ready.stream.makeAsyncIterator()
            guard await iterator.next() == true else { throw CloudTeamScope.Failure.unavailable }
            try check(ticket, identity)
            _ = try capability.snapshot()
        } catch {
            if cycle == ticket { lose(identity, restart: false) }
            throw error
        }
    }

    /// Registration recovery belongs to the explicit sign-in, once per auth session, never a background retry.
    package func beginRegistration(_ identity: AuthenticatedSessionIdentity) -> Bool {
        guard current(identity), registration != identity else { return false }
        registration = identity
        return true
    }

    /// A picker or policy selection change may reselect only within the retained original account/install.
    package func selectionChanged(_ identity: AuthenticatedSessionIdentity, selection: CloudTeamScope.Selection?) {
        guard original?.identity == identity || (original == nil && current(identity)) else { return }
        guard original?.scope.selection != selection else { return }
        reselect = true
        guard current(identity) else { return }
        lose(identity, restart: true)
    }

    /// Initial registration changes are checked by startup itself; an established install change fences idle work.
    package func installChanged(_ identity: AuthenticatedSessionIdentity, generation: UInt64) {
        guard current(identity), original?.identity == identity, original?.scope.installGeneration != generation else { return }
        lose(identity, restart: true)
    }

    /// Clear admission before any await; the lifecycle joins the returned drain before it can start again.
    package func fence() -> Task<Void, Never> {
        capability.clear(); cycle = nil; admitted = false
        readiness?.yield(false); readiness?.finish(); readiness = nil
        let observation = observation, receiver = receiver, opening = opening, previous = draining
        self.observation = nil; self.receiver = nil; self.opening = nil
        receiver?.cancel(); opening?.cancel()
        // task-owner: draining and the lifecycle fence; never cancel away a previous held reader or lease load.
        let drain = Task {
            async let stopped: Void? = observation?.stop()
            _ = await opening?.result
            await receiver?.value
            _ = await stopped
            await previous?.value
        }
        draining = drain
        return drain
    }

    /// Auth-session retirement drops reconciliation authority; a mere observation loss retains it.
    package func retire() -> Task<Void, Never> {
        original = nil; binding = nil; registration = nil; reselect = false
        return fence()
    }

    private func check(_ ticket: UUID, _ identity: AuthenticatedSessionIdentity) throws {
        try Task.checkCancellation()
        guard cycle == ticket, current(identity) else { throw CloudTeamScope.Failure.changed }
    }

    private func receive(_ state: CloudAuthorityWire.State, scope: CloudTeamScope.Snapshot,
                         ticket: UUID, identity: AuthenticatedSessionIdentity) {
        guard cycle == ticket else { return }
        guard current(identity), state == .ready else { lose(identity, restart: admitted); return }
        do {
            try capability.bind(scope, identity: identity)
            admitted = true
            readiness?.yield(true); readiness?.finish(); readiness = nil
        } catch { lose(identity, restart: false) }
    }

    private func lose(_ identity: AuthenticatedSessionIdentity, restart: Bool) {
        _ = fence()
        // No HTTP await here: the parent closes credentials synchronously before joining old work.
        lost(identity, restart)
    }
}
