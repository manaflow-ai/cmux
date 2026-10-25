public import Foundation

/// One stash as the Stashed page shows it: browser pages closed into a
/// group named after the workspace they left (or an imported OneTab group),
/// and whole workspaces saved and closed. The App maps the daemon's
/// `stash.list` records into it.
public nonisolated struct StashedGroup: Identifiable, Hashable, Sendable {
    /// One stashed member: a page, or a whole workspace; its stable ``id`` names it to restore
    /// and delete.
    public struct Tab: Hashable, Sendable, Identifiable {
        /// What a member is.
        public enum Kind: Hashable, Sendable {
            /// A browser page.
            case page
            /// A whole workspace with its tabs (terminals too), restored as its own workspace.
            /// `tabs` are its tabs' titles, for the row; `addresses` its pages' addresses, for search.
            case workspace(tabs: [String], addresses: [String] = [])
        }

        /// The daemon's member id, stable while the page stays stashed.
        public var id: String
        public var kind: Kind
        /// The page's address; empty for a workspace.
        public var url: String
        /// The page title, or the workspace's name.
        public var title: String?
        /// The browser profile it reopens in; nil for the default.
        public var profile: String?

        public init(id: String, kind: Kind = .page, url: String, title: String?, profile: String?) {
            self.id = id
            self.kind = kind
            self.url = url
            self.title = title
            self.profile = profile
        }

        /// The row's title: the page title, else the address (a workspace: its name).
        public var displayTitle: String {
            title.flatMap { $0.isEmpty ? nil : $0 } ?? (isWorkspace ? StashStrings.untitledWorkspace : url)
        }

        public var isWorkspace: Bool {
            if case .workspace = kind { return true }
            return false
        }

        /// A workspace's tab titles; none for a page.
        public var workspaceTabs: [String] {
            if case .workspace(let tabs, _) = kind { return tabs }
            return []
        }

        /// A workspace's page addresses; none for a page.
        public var workspaceAddresses: [String] {
            if case .workspace(_, let addresses) = kind { return addresses }
            return []
        }
    }

    /// The daemon's stash id.
    public var id: String
    /// The workspace's or imported group's name; nil when it had none.
    public var name: String?
    public var createdAt: Date
    public var tabs: [Tab]

    public init(id: String, name: String?, createdAt: Date, tabs: [Tab]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.tabs = tabs
    }
}
