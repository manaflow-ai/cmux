/// The link a Cloud machine's calls go over (``CloudLinkSession``). Each answer is read at each call and never kept.
public struct CloudMachineLinks: Sendable {
    public let appLink: CloudLinkSession?

    public init(appLink: CloudLinkSession?) {
        self.appLink = appLink
    }

    /// The owner answer of the link the calls go over (``CloudLinkSession/ownerLink``).
    public var ownerLink: @Sendable () async -> Int? {
        { [appLink] in await appLink?.ownerLink }
    }

    /// Whether the link says the machine is a teammate's: only names a refused start, never grants one.
    public var teammate: @Sendable () async -> Bool {
        { [appLink] in await appLink?.callerIsTeammate ?? false }
    }
}
