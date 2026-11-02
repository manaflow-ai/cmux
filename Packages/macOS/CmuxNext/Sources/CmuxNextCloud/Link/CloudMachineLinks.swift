/// The links a Cloud machine's calls go over: its app link (``CloudLinkSession``) when it has one,
/// else its legacy link (``CloudMachineLink``). Each answer is read at each call and never kept.
public struct CloudMachineLinks: Sendable {
    public let appLink: CloudLinkSession?
    public let link: CloudMachineLink?

    public init(appLink: CloudLinkSession?, link: CloudMachineLink?) {
        self.appLink = appLink
        self.link = link
    }

    /// The owner answer of the link the calls go over: the app link's own
    /// (``CloudLinkSession/ownerLink``) or the legacy link's (``CloudMachineLink/ownerLink``).
    public var ownerLink: @Sendable () async -> Int? {
        if let appLink { return { await appLink.ownerLink } }
        return { [link] in await link?.ownerLink }
    }

    /// Whether the link the calls go over says the machine is a teammate's (the app link's own
    /// answer, or the legacy link's): only names a refused start, never grants one.
    public var teammate: @Sendable () async -> Bool {
        if let appLink { return { await appLink.callerIsTeammate } }
        return { [link] in await link?.callerIsTeammate ?? false }
    }
}
