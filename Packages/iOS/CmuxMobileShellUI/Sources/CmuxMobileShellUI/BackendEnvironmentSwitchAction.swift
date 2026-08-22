#if os(iOS)
public import CMUXAuthCore
import SwiftUI

/// The live backend-switch entrypoint the app root injects into Settings.
///
/// Mirrors the transaction's phase (so the section can disable its picker
/// while a switch runs) and exposes `beginSwitch(to:)`, which starts the
/// app-root transaction: park the old environment's session, quiesce the old
/// composition, store the override, rebuild the tree, establish a session on
/// the target. The phase enum is a mirror rather than the engine's own type
/// so this UI package stays coupled to a small seam instead of the
/// transaction implementation.
public struct BackendEnvironmentSwitchAction: Sendable {
    /// Where the app-root switch transaction currently is.
    public enum Phase: Equatable, Sendable {
        case idle
        /// Detaching the old environment's session; its token slot survives.
        case parking
        /// Override stored; rebuilding the composition for the target.
        case retargeting
        /// Rebuilt on the target; restoring its parked session or waiting
        /// for an eligible sign-in.
        case establishing
        /// Undoing the switch back to the previous environment.
        case reverting
        case finished
    }

    /// The mirrored transaction phase at the time of injection.
    public let phase: Phase

    private let begin: @MainActor @Sendable (CMUXBackendEnvironmentOverride) -> Void

    public init(
        phase: Phase,
        beginSwitch: @escaping @MainActor @Sendable (CMUXBackendEnvironmentOverride) -> Void
    ) {
        self.phase = phase
        self.begin = beginSwitch
    }

    /// Whether a switch is currently in flight (picker should be inert).
    /// Establishing counts: the run is still deciding between switched and
    /// reverted until the sign-in wait resolves.
    public var isRunning: Bool {
        switch phase {
        case .parking, .retargeting, .establishing, .reverting:
            true
        case .idle, .finished:
            false
        }
    }

    /// Starts (or joins) the live switch to `target`.
    @MainActor
    public func beginSwitch(to target: CMUXBackendEnvironmentOverride) {
        begin(target)
    }
}

private struct BackendEnvironmentSwitchActionEnvironmentKey: EnvironmentKey {
    static let defaultValue: BackendEnvironmentSwitchAction? = nil
}

extension EnvironmentValues {
    /// The app root's live backend-switch action. `nil` in previews and hosts
    /// without the app root, where the picker confirms but performs nothing.
    public var backendEnvironmentSwitchAction: BackendEnvironmentSwitchAction? {
        get { self[BackendEnvironmentSwitchActionEnvironmentKey.self] }
        set { self[BackendEnvironmentSwitchActionEnvironmentKey.self] = newValue }
    }
}

/// Selection → confirmation → action state machine behind the Settings
/// backend picker, extracted from the view so the confirmation seam is
/// directly testable: flipping the picker must never invoke the switch
/// action, confirming invokes it exactly once, and cancelling reverts the
/// visible selection to the active environment.
struct BackendEnvironmentSwitchConfirmation: Equatable {
    /// The environment awaiting user confirmation; drives the dialog.
    private(set) var pendingTarget: CMUXBackendEnvironmentOverride?

    /// The picker's visible selection: the pending target while the dialog is
    /// up, otherwise the active environment.
    func selection(
        active: CMUXBackendEnvironmentOverride
    ) -> CMUXBackendEnvironmentOverride {
        pendingTarget ?? active
    }

    /// Handles a picker selection: choosing the active environment clears any
    /// pending confirmation; anything else parks the target behind the dialog
    /// without invoking the switch.
    mutating func select(
        _ newValue: CMUXBackendEnvironmentOverride,
        active: CMUXBackendEnvironmentOverride
    ) {
        pendingTarget = newValue == active ? nil : newValue
    }

    /// Confirms the pending switch, invoking `beginSwitch` exactly once with
    /// the parked target. No-op when nothing is pending.
    @MainActor
    mutating func confirm(
        using action: BackendEnvironmentSwitchAction?
    ) {
        guard let pendingTarget else { return }
        self.pendingTarget = nil
        action?.beginSwitch(to: pendingTarget)
    }

    /// Cancels the dialog; the picker snaps back to the active environment.
    mutating func cancel() {
        pendingTarget = nil
    }
}
#endif
