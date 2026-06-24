import CmuxBrowser

/// The fully-specified import the wizard produces when the user confirms:
/// which installed browser to read from, the realized-into-cmux execution plan,
/// the data scope, and any optional domain filters.
///
/// Built by ``BrowserImportWizardWindowController`` on confirmation and consumed
/// by ``BrowserDataImportCoordinator`` to drive ``BrowserDataImporter``.
struct BrowserImportSelection {
    /// The source browser to import profiles from.
    let browser: InstalledBrowserCandidate
    /// The source-profile-to-cmux-destination plan, before realization.
    let executionPlan: BrowserImportExecutionPlan
    /// Which data types (cookies, history, both, everything) to import.
    let scope: BrowserImportScope
    /// Optional domain filters; empty means import all domains.
    let domainFilters: [String]
}
