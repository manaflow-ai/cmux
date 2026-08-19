public import CMUXAuthCore
import Foundation
public import Observation

/// The one apply path for a live backend-environment switch, shared by both
/// apps so the ordering invariant has a single owner:
///
/// 1. full sign-out under the OLD defaults (the bounded server tail — Stack
///    revocation, push-token delete, iroh binding revoke — must hit the old
///    backend),
/// 2. quiesce the old environment-frozen graph,
/// 3. store the override (the commit point: per-use resolvers flip here),
/// 4. rebuild the frozen graph against the new environment.
///
/// Storing the override before sign-out completes would mint tokens for one
/// Stack project into a client configured for the other, so steps may never
/// reorder. There is deliberately no failure branch: the platform `signOut`
/// step is local-first with a bounded best-effort server tail (the
/// coordinator's injected-clock deadline), and the transaction proceeds
/// unconditionally once it returns. A crash before the commit point leaves
/// the old environment signed out; after it, the next launch resolves the
/// new environment and the project-switch launch hygiene clears stale state.
@MainActor @Observable
public final class BackendEnvironmentSwitchTransaction {
    /// Where the transaction currently is; drives the Settings progress UI.
    public enum Phase: Equatable, Sendable {
        /// No switch in progress.
        case idle
        /// Signing out of the old environment (old defaults still active).
        case signingOut
        /// Override stored; rebuilding the frozen graph for the new
        /// environment.
        case retargeting
        /// Switch complete; the UI shows the switched note until `reset()`.
        case finished
    }

    /// The platform-injected steps. Each closure runs on the main actor in
    /// the documented order; none may throw.
    public struct Steps {
        /// Whether a build-time bake pins this build's backend. A pinned
        /// build can never start the transaction, independent of UI hiding.
        public let isPinnedByBuild: @MainActor () -> Bool
        /// The environment the running process resolved at composition time.
        public let activeEnvironment: @MainActor () -> CMUXBackendEnvironmentOverride
        /// The platform's complete sign-out flow, run under the OLD defaults.
        public let signOut: @MainActor () async -> Void
        /// Stops services that read the environment per use, closing the
        /// window where they would flip ahead of the still-frozen auth graph.
        public let quiesce: @MainActor () async -> Void
        /// Persists the override; the commit point.
        public let storeOverride: @MainActor (CMUXBackendEnvironmentOverride) -> Void
        /// Rebuilds the environment-frozen graph and unblocks the app.
        public let rebuild: @MainActor (CMUXBackendEnvironmentOverride) async -> Void

        public init(
            isPinnedByBuild: @escaping @MainActor () -> Bool,
            activeEnvironment: @escaping @MainActor () -> CMUXBackendEnvironmentOverride,
            signOut: @escaping @MainActor () async -> Void,
            quiesce: @escaping @MainActor () async -> Void,
            storeOverride: @escaping @MainActor (CMUXBackendEnvironmentOverride) -> Void,
            rebuild: @escaping @MainActor (CMUXBackendEnvironmentOverride) async -> Void
        ) {
            self.isPinnedByBuild = isPinnedByBuild
            self.activeEnvironment = activeEnvironment
            self.signOut = signOut
            self.quiesce = quiesce
            self.storeOverride = storeOverride
            self.rebuild = rebuild
        }
    }

    public private(set) var phase: Phase = .idle
    /// The in-flight run; concurrent callers join it instead of starting a
    /// second transaction (mirroring `HostBrowserSignOutCoordinator`).
    private var activeRun: Task<Void, Never>?

    public init() {}

    /// Run one switch to `target`. Joins an already-active run; refuses when
    /// the build is pinned or `target` is already the active environment.
    public func run(to target: CMUXBackendEnvironmentOverride, steps: Steps) async {
        if let activeRun {
            await activeRun.value
            return
        }
        if phase == .finished {
            phase = .idle
        }
        guard phase == .idle else { return }
        guard !steps.isPinnedByBuild() else { return }
        guard steps.activeEnvironment() != target else { return }

        let run = Task { @MainActor in
            self.phase = .signingOut
            await steps.signOut()
            await steps.quiesce()
            self.phase = .retargeting
            steps.storeOverride(target)
            await steps.rebuild(target)
            self.phase = .finished
        }
        activeRun = run
        await run.value
        activeRun = nil
    }

    /// Returns to `.idle` after the UI has shown the switched note. A new
    /// `run` also clears `.finished` defensively.
    public func reset() {
        guard phase == .finished else { return }
        phase = .idle
    }
}
