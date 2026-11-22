import Foundation

/// One browser tab as the provider announces it.
public nonisolated struct ProviderTab: Hashable, Sendable {
    /// The store's tab id.
    public var targetID: String
    public var engine: ProviderEngine
    public var workspace: String
    public var profile: String
    public var url: String
    public var title: String
    public var visible: Bool

    public init(targetID: String, engine: ProviderEngine, workspace: String, profile: String, url: String, title: String, visible: Bool) {
        self.targetID = targetID
        self.engine = engine
        self.workspace = workspace
        self.profile = profile
        self.url = url
        self.title = title
        self.visible = visible
    }

    public var announce: ProviderTabAnnounce {
        ProviderTabAnnounce(targetID: targetID, engine: engine.rawValue, workspace: workspace, profile: profile,
                            url: url, title: title, visible: visible)
    }
}

/// The extension access of a CEF tab (`tab.access`): `extensionHostAccess`
/// when an enabled extension of the tab's profile can reach its page,
/// `userOverride` when the person allowed agents in the tab anyway.
public nonisolated struct ProviderTabAccess: Hashable, Sendable {
    public var extensionHostAccess: Bool
    public var userOverride: Bool
    /// Names of the extensions that can reach the page.
    public var extensions: [String]

    public init(extensionHostAccess: Bool, userOverride: Bool, extensions: [String]) {
        self.extensionHostAccess = extensionHostAccess
        self.userOverride = userOverride
        self.extensions = extensions
    }
}
