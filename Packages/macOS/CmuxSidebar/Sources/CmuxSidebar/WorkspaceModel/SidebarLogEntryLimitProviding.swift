/// Supplies the configured maximum number of sidebar log entries the model
/// retains, inverting the `Workspace`-side `UserDefaults` read that the legacy
/// `appendSidebarLog` performed inline.
///
/// The app target conforms this to the real `UserDefaults`-backed lookup
/// (`UserDefaults.standard.object(forKey: "sidebarMaxLogEntries")`); tests pass
/// a fake returning a fixed value. The model clamps whatever this returns to
/// the legacy `1...500` range, so a conformer only needs to report the raw
/// configured value (or `nil` when unset, which the model treats as the legacy
/// default of 50).
public protocol SidebarLogEntryLimitProviding: Sendable {
    /// The configured maximum sidebar log-entry count, or `nil` when no value
    /// is configured. The model applies the legacy default and clamping.
    var configuredMaxSidebarLogEntries: Int? { get }
}
