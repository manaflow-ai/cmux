public import CMUXAuthCore
import Foundation
public import Observation

/// The one apply path for a live backend-environment switch, shared by both
/// apps so the ordering invariant has a single owner:
///
/// 1. PARK the session under the OLD defaults — detach the published state
///    while the old environment's token slot survives for the return switch
///    (no revocation, no token delete),
/// 2. quiesce the old environment-frozen graph,
/// 3. store the override (the commit point: per-use resolvers flip here),
/// 4. rebuild the frozen graph against the new environment,
/// 5. ESTABLISH a session on the target: restore its parked slot, and for a
///    gated target (staging) require an eligible signed-in user — restoring
///    silently when the parked session qualifies, prompting inline otherwise,
///    and REVERTING to the previous environment (which never gates and never
///    prompts) when the prompt is cancelled, fails, or yields an ineligible
///    user.
///
/// Storing the override before the park completes would mint tokens for one
/// Stack project into a client configured for the other, so steps 1–4 may
/// never reorder; the override is never stored while `parkSession` is in
/// flight. The park is local-first and unconditional (no failure branch). A
/// crash before the commit point leaves the old environment parked; after
/// it, the next launch resolves the new environment and (thanks to the
/// one-shot rebuild marker armed by every `storeOverride`) restores the
/// target's parked slot. A crash mid-establishing strands the device on the
/// target signed out with the previous slot still parked — exactly the state
/// the Settings recovery card handles.
@MainActor @Observable
public final class BackendEnvironmentSwitchTransaction {
    /// Why a switch ended back on the previous environment.
    public enum RevertReason: Equatable, Sendable {
        /// The user cancelled the target's sign-in prompt (or requested the
        /// revert explicitly through ``requestRevert()``).
        case signInCancelled
        /// The target's sign-in prompt failed (timeout, network, server).
        case signInFailed
        /// The sign-in completed but the account is not eligible for the
        /// gated target; the established session was signed out for real
        /// (under the target's defaults) before reverting.
        case notEligible
    }

    /// How a completed run ended.
    public enum Outcome: Equatable, Sendable {
        /// The device is on the requested target with a session established
        /// (or with none required).
        case switched
        /// The device is back on the previous environment with its parked
        /// session restored.
        case reverted(RevertReason)
    }

    /// The platform's classification of a `promptSignIn` that resolved
    /// without a user, mapping onto the two prompt-driven revert reasons.
    public enum SignInPromptFailure: Equatable, Sendable {
        /// The user backed out (closed the browser popup / dismissed the
        /// sheet); no error to surface.
        case cancelled
        /// The attempt failed (timeout, network, server, unusable browser).
        case failed
    }

    /// Where the transaction currently is; drives the Settings progress UI.
    public enum Phase: Equatable, Sendable {
        /// No switch in progress.
        case idle
        /// Parking the old environment's session (old defaults still
        /// active): published state detaches, the token slot survives.
        case parking
        /// Override stored; rebuilding the frozen graph for the new
        /// environment.
        case retargeting
        /// Rebuilt on the target; restoring its parked session and — for a
        /// gated target — waiting for an eligible sign-in.
        case establishing
        /// Undoing the switch: rebuilding the previous environment and
        /// restoring its parked session. Never gates, never prompts.
        case reverting
        /// Run complete; the UI shows the outcome until `reset()`.
        case finished(Outcome)
    }

    /// The platform-injected steps. Each closure runs on the main actor in
    /// the documented order; none may throw. Timeouts live inside the
    /// platform steps (the engine never sleeps).
    public struct Steps {
        /// Whether a build-time bake pins this build's backend. A pinned
        /// build can never start the transaction, independent of UI hiding.
        public let isPinnedByBuild: @MainActor () -> Bool
        /// The environment the running process resolved at composition time.
        public let activeEnvironment: @MainActor () -> CMUXBackendEnvironmentOverride
        /// Parks the session under the OLD defaults: detaches the published
        /// state and clears platform session surfaces, leaving the token
        /// slot untouched and skipping every server-side teardown.
        public let parkSession: @MainActor () async -> Void
        /// Stops services that read the environment per use, closing the
        /// window where they would flip ahead of the still-frozen auth graph.
        public let quiesce: @MainActor () async -> Void
        /// Persists the override; the commit point. Platforms also arm the
        /// one-shot rebuild marker here so the rebuild (or a post-crash
        /// launch) restores the target's parked slot instead of clearing it.
        public let storeOverride: @MainActor (CMUXBackendEnvironmentOverride) -> Void
        /// Rebuilds the environment-frozen graph and unblocks the app.
        public let rebuild: @MainActor (CMUXBackendEnvironmentOverride) async -> Void
        /// Awaits the rebuilt graph's launch restore and returns the user it
        /// restored from the target's parked slot, or `nil` when the slot
        /// was empty or the restore did not produce a session.
        public let awaitRestoredUser: @MainActor () async -> CMUXAuthUser?
        /// Runs the platform's interactive sign-in against the CURRENT
        /// (target) environment and returns the signed-in user, or `nil` on
        /// cancel / failure / timeout (classified by
        /// ``Steps/signInPromptFailure``).
        public let promptSignIn: @MainActor () async -> CMUXAuthUser?
        /// Resolves an in-flight `promptSignIn` as cancelled (used by
        /// ``requestRevert()``).
        public let cancelSignInPrompt: @MainActor () -> Void
        /// The REAL sign-out chain, run under the CURRENT (target) defaults
        /// so revoking an ineligible session hits the target's backend.
        public let signOutEstablishedSession: @MainActor () async -> Void
        /// Whether `user` may hold a session on a gated target (the switch
        /// gate, or a DEBUG build).
        public let isEligible: @MainActor (CMUXAuthUser) -> Bool
        /// Classifies a `promptSignIn` that returned `nil` (consulted only
        /// when no revert was requested; ``requestRevert()`` always reverts
        /// as cancelled).
        public let signInPromptFailure: @MainActor () -> SignInPromptFailure

        public init(
            isPinnedByBuild: @escaping @MainActor () -> Bool,
            activeEnvironment: @escaping @MainActor () -> CMUXBackendEnvironmentOverride,
            parkSession: @escaping @MainActor () async -> Void,
            quiesce: @escaping @MainActor () async -> Void,
            storeOverride: @escaping @MainActor (CMUXBackendEnvironmentOverride) -> Void,
            rebuild: @escaping @MainActor (CMUXBackendEnvironmentOverride) async -> Void,
            awaitRestoredUser: @escaping @MainActor () async -> CMUXAuthUser?,
            promptSignIn: @escaping @MainActor () async -> CMUXAuthUser?,
            cancelSignInPrompt: @escaping @MainActor () -> Void,
            signOutEstablishedSession: @escaping @MainActor () async -> Void,
            isEligible: @escaping @MainActor (CMUXAuthUser) -> Bool,
            signInPromptFailure: @escaping @MainActor () -> SignInPromptFailure
        ) {
            self.isPinnedByBuild = isPinnedByBuild
            self.activeEnvironment = activeEnvironment
            self.parkSession = parkSession
            self.quiesce = quiesce
            self.storeOverride = storeOverride
            self.rebuild = rebuild
            self.awaitRestoredUser = awaitRestoredUser
            self.promptSignIn = promptSignIn
            self.cancelSignInPrompt = cancelSignInPrompt
            self.signOutEstablishedSession = signOutEstablishedSession
            self.isEligible = isEligible
            self.signInPromptFailure = signInPromptFailure
        }
    }

    public private(set) var phase: Phase = .idle
    /// The in-flight run; concurrent callers join it instead of starting a
    /// second transaction (mirroring `HostBrowserSignOutCoordinator`).
    private var activeRun: Task<Void, Never>?
    /// Set by ``requestRevert()`` during `.establishing`; checked after each
    /// establishing await so the revert wins over a racing prompt result.
    private var revertRequested = false
    /// The active run's steps, kept so ``requestRevert()`` can resolve an
    /// in-flight sign-in prompt.
    @ObservationIgnored private var activeSteps: Steps?

    public init() {}

    /// Run one switch to `target`. Joins an already-active run; refuses when
    /// the build is pinned or `target` is already the active environment.
    public func run(to target: CMUXBackendEnvironmentOverride, steps: Steps) async {
        if let activeRun {
            await activeRun.value
            return
        }
        if case .finished = phase {
            phase = .idle
        }
        guard phase == .idle else { return }
        guard !steps.isPinnedByBuild() else { return }
        let previous = steps.activeEnvironment()
        guard previous != target else { return }

        revertRequested = false
        activeSteps = steps
        let run = Task { @MainActor in
            self.phase = .parking
            await steps.parkSession()
            await steps.quiesce()
            self.phase = .retargeting
            steps.storeOverride(target)
            await steps.rebuild(target)
            await self.establish(target: target, previous: previous, steps: steps)
        }
        activeRun = run
        await run.value
        activeRun = nil
        activeSteps = nil
    }

    /// Request that an in-flight switch revert to the previous environment.
    /// Valid only during `.establishing` (the sign-in wait); resolves the
    /// prompt as cancelled and the run finishes `.reverted(.signInCancelled)`.
    public func requestRevert() {
        guard phase == .establishing else { return }
        revertRequested = true
        activeSteps?.cancelSignInPrompt()
    }

    /// Returns to `.idle` after the UI has shown the outcome. A new `run`
    /// also clears a stale `.finished` defensively.
    public func reset() {
        guard case .finished = phase else { return }
        phase = .idle
    }

    // MARK: - Establishing

    /// Establish a session on the (already rebuilt) target.
    ///
    /// Ungated targets (production) NEVER consult the prompt or the gate:
    /// they await the launch restore of the parked slot and finish switched,
    /// signed in or not. Gated targets (staging) finish switched only with
    /// an eligible user: a restored eligible session completes silently
    /// (repeated switching never re-prompts); a restored ineligible session
    /// is signed out for real (under the target's defaults) before the
    /// inline prompt; a cancelled / failed prompt, an ineligible prompted
    /// user, or a ``requestRevert()`` reverts to `previous`.
    private func establish(
        target: CMUXBackendEnvironmentOverride,
        previous: CMUXBackendEnvironmentOverride,
        steps: Steps
    ) async {
        phase = .establishing
        guard target.requiresGatedSession else {
            _ = await steps.awaitRestoredUser()
            phase = .finished(.switched)
            return
        }

        let restored = await steps.awaitRestoredUser()
        if revertRequested {
            await revert(to: previous, reason: .signInCancelled, steps: steps)
            return
        }
        if let restored {
            if steps.isEligible(restored) {
                phase = .finished(.switched)
                return
            }
            // An ineligible parked session must not survive on the gated
            // target: sign it out for real (revocation hits the target's
            // backend, since its defaults are active) and fall through to
            // the prompt.
            await steps.signOutEstablishedSession()
            if revertRequested {
                await revert(to: previous, reason: .signInCancelled, steps: steps)
                return
            }
        }

        let prompted = await steps.promptSignIn()
        if let prompted {
            guard steps.isEligible(prompted) else {
                // Sign the just-established ineligible session out for real
                // before reverting — regardless of a concurrent revert
                // request, so an ineligible session never stays parked on
                // the gated target.
                await steps.signOutEstablishedSession()
                await revert(to: previous, reason: .notEligible, steps: steps)
                return
            }
            if revertRequested {
                await revert(to: previous, reason: .signInCancelled, steps: steps)
                return
            }
            phase = .finished(.switched)
            return
        }
        let reason: RevertReason = revertRequested
            ? .signInCancelled
            : (steps.signInPromptFailure() == .cancelled ? .signInCancelled : .signInFailed)
        await revert(to: previous, reason: reason, steps: steps)
    }

    /// Undo the switch: quiesce the target's graph, store the previous
    /// override (arming the rebuild marker again), rebuild, and await the
    /// previous environment's parked session. NEVER gates and NEVER prompts
    /// (pinned by tests), so a revert can't loop.
    private func revert(
        to previous: CMUXBackendEnvironmentOverride,
        reason: RevertReason,
        steps: Steps
    ) async {
        phase = .reverting
        await steps.quiesce()
        steps.storeOverride(previous)
        await steps.rebuild(previous)
        _ = await steps.awaitRestoredUser()
        phase = .finished(.reverted(reason))
    }
}
