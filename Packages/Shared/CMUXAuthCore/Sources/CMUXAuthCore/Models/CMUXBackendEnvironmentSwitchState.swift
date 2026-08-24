import Foundation

/// The runtime backend-environment switch surface a composition root hands to
/// Settings.
///
/// ``selection`` is the backend selection the owning composition resolved when
/// it was built: `.explicit` when the wholesale choice key was persisted,
/// `.lane` otherwise. The live switch transaction (park the session under the
/// old defaults, quiesce the old graph, store the selection, rebuild the
/// composition) replaces the whole root, so `selection` converges to the
/// user's choice by re-injection from the new root; the persisted choice is
/// written only by the transaction's commit step, never by the picker
/// directly. ``buildLane`` is the build's own lane — what this install is
/// baked to when NO explicit choice is persisted — classified once per build
/// pass from the build-time overrides alone. It powers the picker's option-set
/// rule (a production-lane build keeps the two-position picker; every other
/// lane adds a "Build lane (…)" position) and the lane footer that explains
/// the bake. There is no pinned/refusal state left: an explicit choice is a
/// wholesale override that beats every bake, so the picker always works.
public struct CMUXBackendEnvironmentSwitchState: Equatable, Sendable {
    /// The backend selection the owning composition root resolved.
    public let selection: CMUXBackendEnvironmentSelection

    /// The build's own lane (the backend resolved with no explicit choice),
    /// classified from build-time overrides with the choice ignored.
    public let buildLane: CMUXBackendEnvironmentBuildLane

    /// Creates the switch state for one composition root.
    public init(
        selection: CMUXBackendEnvironmentSelection,
        buildLane: CMUXBackendEnvironmentBuildLane
    ) {
        self.selection = selection
        self.buildLane = buildLane
    }
}
