/// A fully realized import plan: every entry points at a concrete cmux
/// destination profile, plus the set of profiles that had to be created.
public struct RealizedBrowserImportExecutionPlan: Sendable {
    /// How source profiles map onto destination profiles.
    public let mode: BrowserImportDestinationMode
    /// The realized source-to-destination mappings.
    public let entries: [RealizedBrowserImportExecutionEntry]
    /// Destination profiles created while realizing the plan.
    public let createdProfiles: [BrowserProfileDefinition]

    /// Creates a realized import execution plan.
    ///
    /// - Parameters:
    ///   - mode: How source profiles map onto destination profiles.
    ///   - entries: The realized source-to-destination mappings.
    ///   - createdProfiles: Destination profiles created while realizing the plan.
    public init(
        mode: BrowserImportDestinationMode,
        entries: [RealizedBrowserImportExecutionEntry],
        createdProfiles: [BrowserProfileDefinition]
    ) {
        self.mode = mode
        self.entries = entries
        self.createdProfiles = createdProfiles
    }
}
