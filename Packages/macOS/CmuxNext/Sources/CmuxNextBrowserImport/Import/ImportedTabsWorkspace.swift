public import Foundation

/// A source profile's open tabs as one workspace: named after the source
/// ("Google Chrome · Work"), on the browser profile its data went to.
public struct ImportedTabsWorkspace: Sendable, Equatable {
    public var name: String
    public var profileID: String
    /// Web pages only, in the source's window then tab order.
    public var tabs: [ImportedTab]
}

extension ImportSummary {
    /// One workspace per source profile with a web page open; the browser's
    /// own pages (chrome://, about:) and local files stay behind.
    public var tabWorkspaces: [ImportedTabsWorkspace] {
        batches.compactMap { batch in
            let tabs = batch.openTabs.filter { ["http", "https"].contains($0.url.scheme?.lowercased()) }
            return tabs.isEmpty ? nil : ImportedTabsWorkspace(name: batch.source.displayName, profileID: batch.source.targetProfileID, tabs: tabs)
        }
    }
}
