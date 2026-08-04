/// Resolves how many custom metadata entries a collapsed workspace row presents.
public struct SidebarMetadataCollapsePolicy: Equatable, Sendable {
    private let configuredLimit: Int

    /// Creates a metadata collapse policy.
    ///
    /// Non-positive values disable collapsing.
    ///
    /// - Parameter configuredLimit: The requested number of persistently visible
    ///   entries, or zero to request unlimited display.
    public init(configuredLimit: Int) {
        self.configuredLimit = max(0, configuredLimit)
    }

    /// Returns the entries that the workspace row should currently render.
    ///
    /// - Parameters:
    ///   - entries: The authoritative metadata entries in display order.
    ///   - isExpanded: Whether the user explicitly expanded this workspace row.
    /// - Returns: Every entry when expanded or collapsing is disabled; otherwise,
    ///   the configured collapsed prefix.
    public func visibleEntries(
        _ entries: [SidebarStatusEntry],
        isExpanded: Bool
    ) -> [SidebarStatusEntry] {
        guard configuredLimit > 0,
              !isExpanded,
              entries.count > configuredLimit else {
            return entries
        }
        return Array(entries.prefix(configuredLimit))
    }

    /// Returns whether the row needs a control to reveal entries beyond its collapsed prefix.
    ///
    /// - Parameter entryCount: The authoritative number of metadata entries.
    /// - Returns: `true` when explicit expansion can reveal additional entries.
    public func showsExpansionToggle(entryCount: Int) -> Bool {
        configuredLimit > 0 && entryCount > configuredLimit
    }
}
