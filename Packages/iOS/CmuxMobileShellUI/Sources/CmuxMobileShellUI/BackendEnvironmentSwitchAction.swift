#if os(iOS)
public import CMUXAuthCore
import SwiftUI

/// The Settings backend picker's option: the build's own lane, or an
/// explicitly chosen environment.
///
/// A picker-facing mirror of the host's `CMUXBackendEnvironmentSelection`:
/// `.production` and `.staging` are EXPLICIT wholesale choices, while
/// `.buildLane` returns the build to its own bake (the app root maps it to
/// clearing the persisted choice). The mapping of `.production` is
/// lane-dependent and lives in the APP ROOT, not here: on a production-lane
/// build "Production" maps to the lane (key removal, preserving the
/// two-position picker's pre-tri-state semantics), on any other lane it is
/// the explicit wholesale choice.
public enum MobileBackendEnvironmentSelection: Equatable, Hashable, Sendable {
    /// No explicit choice: run whatever this build is baked to.
    case buildLane
    /// Explicitly pin the production backend.
    case production
    /// Explicitly pin the staging backend (gated, intercepts sign-out).
    case staging

    /// The option-set rule: a production-lane build shows today's
    /// two-position picker (its "Production" maps to clearing the choice in
    /// the app root, so the lane and the option coincide); every other lane
    /// gets a third "Build lane (…)" position ahead of the explicit pair.
    public static func pickerOptions(
        for lane: CMUXBackendEnvironmentBuildLane
    ) -> [MobileBackendEnvironmentSelection] {
        lane == .production
            ? [.production, .staging]
            : [.buildLane, .production, .staging]
    }

    /// The environment this option resolves to on a build with `lane`.
    public func resolvedEnvironment(
        lane: CMUXBackendEnvironmentBuildLane
    ) -> CMUXBackendEnvironmentOverride {
        switch self {
        case .buildLane: lane.resolvedEnvironment
        case .production: .production
        case .staging: .staging
        }
    }
}

/// The live backend-switch entrypoint the app root injects into Settings.
///
/// Mirrors the transaction's phase (so the section can disable its picker
/// while a switch runs) and exposes `beginSwitch(to:)`, which starts the
/// app-root transaction: park the old environment's session, quiesce the old
/// composition, store the selection, rebuild the tree, establish a session on
/// the target. The phase enum is a mirror rather than the engine's own type
/// so this UI package stays coupled to a small seam instead of the
/// transaction implementation; the target is the picker option, mapped to the
/// host selection (including the production-lane "Production"→lane rule) by
/// the app root.
public struct BackendEnvironmentSwitchAction: Sendable {
    /// Where the app-root switch transaction currently is.
    public enum Phase: Equatable, Sendable {
        case idle
        /// Detaching the old environment's session; its token slot survives.
        case parking
        /// Selection stored; rebuilding the composition for the target.
        case retargeting
        /// Rebuilt on the target; restoring its parked session or waiting
        /// for an eligible sign-in.
        case establishing
        /// Undoing the switch back to the previous selection.
        case reverting
        case finished
    }

    /// The mirrored transaction phase at the time of injection.
    public let phase: Phase

    private let begin: @MainActor @Sendable (MobileBackendEnvironmentSelection) -> Void

    public init(
        phase: Phase,
        beginSwitch: @escaping @MainActor @Sendable (MobileBackendEnvironmentSelection) -> Void
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
    public func beginSwitch(to target: MobileBackendEnvironmentSelection) {
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
/// visible selection to the active option.
struct BackendEnvironmentSwitchConfirmation: Equatable {
    /// The picker option awaiting user confirmation; drives the dialog.
    private(set) var pendingTarget: MobileBackendEnvironmentSelection?

    /// The picker's visible selection: the pending target while the dialog is
    /// up, otherwise the active option.
    func selection(
        active: MobileBackendEnvironmentSelection
    ) -> MobileBackendEnvironmentSelection {
        pendingTarget ?? active
    }

    /// Handles a picker selection: choosing the active option clears any
    /// pending confirmation; anything else parks the target behind the dialog
    /// without invoking the switch.
    mutating func select(
        _ newValue: MobileBackendEnvironmentSelection,
        active: MobileBackendEnvironmentSelection
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

    /// Cancels the dialog; the picker snaps back to the active option.
    mutating func cancel() {
        pendingTarget = nil
    }
}
#endif
