/// The live-app seam for the worker-lane `sidebar.custom.*` control commands,
/// read by ``ControlSidebarCustomWorker``.
///
/// The validation, the reload/select side effects, and the localized error
/// strings all live app-side because they reach types the control package must
/// not import (the `CmuxSwiftRenderUI` validator/reload notification and the
/// app's `CmuxExtensionSidebarSelection` / `SettingCatalog`).
///
/// ## Isolation
///
/// `Sendable`, NOT `@MainActor`: these commands run on the nonisolated
/// socket-worker lane. ``validate(name:)`` is synchronous and runs the heavy
/// SwiftUI-interpreter validation ON the worker thread, exactly as the legacy
/// `nonisolated` bodies did (it touches no main-actor state, only the static
/// sidebars directory). ``reload(name:)`` and ``select(name:)`` are `async`
/// because their side effects (the `.customSidebarReloadRequested` post, the
/// beta-feature flag write, the provider selection) mutate main-actor-adjacent
/// state and hop to the main actor inside the conformer, matching the legacy
/// `v2MainSync` blocks.
public protocol ControlSidebarCustomReading: Sendable {
    /// The localized `sidebar.custom.*` error messages, resolved against the
    /// app bundle.
    ///
    /// - Returns: The localized strings.
    func strings() -> ControlSidebarCustomStrings

    /// Validates the custom sidebars for `sidebar.custom.validate` (the name is
    /// already non-empty when provided; `nil` validates the whole directory).
    /// Runs on the calling worker thread.
    ///
    /// - Parameter name: The trimmed sidebar name, or `nil` for all sidebars.
    /// - Returns: The validation report snapshot.
    func validate(name: String?) -> ControlSidebarCustomReport

    /// Validates and triggers a reload for `sidebar.custom.reload`: posts the
    /// `.customSidebarReloadRequested` notification for every reported name (the
    /// legacy `report.names` gate) before returning. The notification post hops
    /// to the main actor; the validation runs on the worker thread.
    ///
    /// - Parameter name: The trimmed sidebar name, or `nil` for all sidebars.
    /// - Returns: The validation report snapshot.
    func reload(name: String?) async -> ControlSidebarCustomReport

    /// Validates and, when the first matching sidebar is valid, applies the
    /// selection for `sidebar.custom.select` (enables the beta feature, sets the
    /// extension-sidebar provider, posts the reload notification). The side
    /// effects hop to the main actor; the validation runs on the worker thread.
    ///
    /// - Parameter name: The trimmed, non-empty sidebar name.
    /// - Returns: The select outcome (which branch the legacy body took).
    func select(name: String) async -> ControlSidebarCustomSelectOutcome
}
