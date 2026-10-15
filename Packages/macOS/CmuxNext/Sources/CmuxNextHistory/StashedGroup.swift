public import Foundation

/// One stash as the Stashed page shows it: browser pages closed into a
/// group named after the workspace they left (or an imported OneTab group).
/// The App maps the daemon's `stash.list` records into it.
public nonisolated struct StashedGroup: Identifiable, Hashable, Sendable {
    /// One stashed page; its stable ``id`` names it to restore and delete.
    public struct Tab: Hashable, Sendable, Identifiable {
        /// The daemon's member id, stable while the page stays stashed.
        public var id: String
        public var url: String
        public var title: String?
        /// The browser profile it reopens in; nil for the default.
        public var profile: String?

        public init(id: String, url: String, title: String?, profile: String?) {
            self.id = id
            self.url = url
            self.title = title
            self.profile = profile
        }

        /// The row's title: the page title, else the address.
        public var displayTitle: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? url }
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
