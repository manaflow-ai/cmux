/// The outcome of the app-side `sidebar.custom.select` body, carrying the
/// validation report plus the branch the legacy body took, so
/// ``ControlSidebarCustomWorker`` formats the matching reply payload. The select
/// side effects (beta-feature flag, provider-id selection, reload notification)
/// run app-side on the main actor before this value is returned — exactly the
/// order the original body used inside its `v2MainSync` block.
public enum ControlSidebarCustomSelectOutcome: Sendable, Equatable {
    /// No sidebars matched the requested name (the legacy
    /// `report.entries.first == nil` branch): reply with the bare report.
    case report(ControlSidebarCustomReport)

    /// The first matching sidebar failed validation (the legacy
    /// `entry.errorMessage != nil` branch): reply with the report plus the
    /// `message` field.
    case entryError(ControlSidebarCustomReport, message: String)

    /// The sidebar was selected (side effects applied app-side): reply with the
    /// report plus `selected_provider_id` and `selected_name`.
    case selected(ControlSidebarCustomReport, providerID: String, name: String)
}
