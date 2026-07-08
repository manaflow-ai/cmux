import Foundation

/// Derived layout flags for the import wizard's destination step, computed from
/// the resolved execution plan.
public struct BrowserImportStep3Presentation: Equatable, Sendable {
    /// Whether the single-vs-separate destination-mode selector is shown.
    public let showsModeSelector: Bool
    /// Whether per-source-profile destination rows are shown.
    public let showsSeparateRows: Bool
    /// Whether a single shared destination picker is shown.
    public let showsSingleDestinationPicker: Bool

    /// Computes the destination-step layout flags for a plan.
    ///
    /// - Parameter plan: The resolved import execution plan.
    public init(plan: BrowserImportExecutionPlan) {
        showsModeSelector = plan.entries.count > 1 || plan.entries.contains { $0.sourceProfiles.count > 1 }
        showsSeparateRows = plan.mode == .separateProfiles
        showsSingleDestinationPicker = plan.mode != .separateProfiles
    }
}
