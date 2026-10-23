public import CmuxNextCompat

extension StashedGroup.Tab {
    /// The row's title: the page title, else the address (a workspace: its name).
    public nonisolated var displayTitle: String {
        title.flatMap { $0.isEmpty ? nil : $0 } ?? (isWorkspace ? StashStrings.untitledWorkspace : url)
    }
}
