internal import CmuxMobileRPC

/// Main-actor actions passed through the lazy-list snapshot boundary.
struct ChangesScreenActions: Sendable {
    /// Retries the summary request.
    let retrySummary: @MainActor @Sendable () -> Void
    /// Selects a Git comparison base and refreshes the screen.
    let selectBase: @MainActor @Sendable (MobileChangesBaseKind) -> Void
    /// Toggles whitespace-ignore and refreshes all data.
    let toggleWhitespace: @MainActor @Sendable () -> Void
    /// Collapses every file section.
    let collapseAll: @MainActor @Sendable () -> Void
    /// Expands every non-gated file section.
    let expandAll: @MainActor @Sendable () -> Void
    /// Toggles one file section.
    let toggleFile: @MainActor @Sendable (String) -> Void
    /// Toggles viewed state and applies GitHub's collapse-on-view behavior.
    let toggleViewed: @MainActor @Sendable (String) -> Void
    /// Loads or retries one file diff.
    let loadFile: @MainActor @Sendable (String) -> Void
    /// Copies a repository-relative path.
    let copyPath: @MainActor @Sendable (String) -> Void
    /// Expands omitted context in one direction.
    let expandGap: @MainActor @Sendable (String, String, ContextExpansionDirection) -> Void

    /// Creates an action bundle for immutable list rows.
    init(
        retrySummary: @escaping @MainActor @Sendable () -> Void,
        selectBase: @escaping @MainActor @Sendable (MobileChangesBaseKind) -> Void,
        toggleWhitespace: @escaping @MainActor @Sendable () -> Void,
        collapseAll: @escaping @MainActor @Sendable () -> Void,
        expandAll: @escaping @MainActor @Sendable () -> Void,
        toggleFile: @escaping @MainActor @Sendable (String) -> Void,
        toggleViewed: @escaping @MainActor @Sendable (String) -> Void,
        loadFile: @escaping @MainActor @Sendable (String) -> Void,
        copyPath: @escaping @MainActor @Sendable (String) -> Void,
        expandGap: @escaping @MainActor @Sendable (String, String, ContextExpansionDirection) -> Void
    ) {
        self.retrySummary = retrySummary
        self.selectBase = selectBase
        self.toggleWhitespace = toggleWhitespace
        self.collapseAll = collapseAll
        self.expandAll = expandAll
        self.toggleFile = toggleFile
        self.toggleViewed = toggleViewed
        self.loadFile = loadFile
        self.copyPath = copyPath
        self.expandGap = expandGap
    }
}
