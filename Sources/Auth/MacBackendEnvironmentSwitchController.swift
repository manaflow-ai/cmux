import CMUXAuthCore
import CmuxAuthRuntime
import Foundation
import Observation

/// Drives the live macOS backend-environment switch from the Settings card.
///
/// Owned by ``HostAccountFlow`` (constructed once in ``MacAuthComposition``'s
/// startup initializer and kept stable across switches, since the flow itself
/// survives the rebuild). The controller owns the shared
/// ``CmuxAuthRuntime/BackendEnvironmentSwitchTransaction`` and takes the
/// macOS steps as an injected
/// ``CmuxAuthRuntime/BackendEnvironmentSwitchTransaction/Steps`` value, so
/// tests can run it against pure fakes without AppKit. The production steps
/// (built in ``MacAuthComposition``) are:
///
/// - `signOut` runs the complete existing teardown chain under the OLD
///   defaults (``HostAccountFlow/signOut()`` →
///   `HostBrowserSignInFlow.signOut()`, which also cancels in-flight sign-in
///   attempts).
/// - `quiesce` stops `MobileHostService` so mobile RPC caller verification
///   (which builds ephemeral `StackClientApp`s from per-use `AuthEnvironment`
///   reads) cannot run against flipped defaults while the old coordinator
///   still lives. Other per-use `AuthEnvironment` readers (`VMClient`,
///   `RemotesClient`, billing fetches, …) are token-less after the sign-out
///   step and fail closed, so they need no quiesce of their own.
/// - `storeOverride` persists the override (the commit point); per-use
///   resolvers (and `PresenceHeartbeatClient`, which self-restarts on
///   `UserDefaults.didChangeNotification`) flip here.
/// - `rebuild` constructs the fresh auth graph for the new environment and
///   hands it to `AppDelegate.adoptRebuiltAuth(_:)`, which restarts
///   `MobileHostService` and ends the quiesce window.
@MainActor
@Observable
final class MacBackendEnvironmentSwitchController {
    private let transaction = BackendEnvironmentSwitchTransaction()
    @ObservationIgnored private let steps: BackendEnvironmentSwitchTransaction.Steps
    /// Whether a switch call is currently in flight. `HostAccountFlow` ORs
    /// this into `isWorkingOnAuth` so every account/auth entrypoint disables
    /// for the whole window, including the brief spans before the transaction
    /// publishes `.signingOut` and after it publishes `.finished`.
    private(set) var isSwitching = false

    /// The transaction's phase; drives the Settings progress UI.
    var phase: BackendEnvironmentSwitchTransaction.Phase {
        transaction.phase
    }

    init(steps: BackendEnvironmentSwitchTransaction.Steps) {
        self.steps = steps
    }

    /// Run one live switch to `target`. Joins an already-active transaction
    /// run; refuses pinned builds and no-op targets (the transaction owns
    /// those guards).
    func switchEnvironment(to target: CMUXBackendEnvironmentOverride) async {
        isSwitching = true
        defer { isSwitching = false }
        await transaction.run(to: target, steps: steps)
    }

    /// Returns the phase to `.idle` after the UI has shown the switched note.
    func reset() {
        transaction.reset()
    }
}
