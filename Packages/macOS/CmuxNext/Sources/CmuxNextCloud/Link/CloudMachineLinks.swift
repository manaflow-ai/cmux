/// The link a Cloud machine's calls go over (``CloudLinkSession``). Each answer is read at each call and never kept.
public struct CloudMachineLinks: Sendable {
    public let appLink: CloudLinkSession

    public init(appLink: CloudLinkSession) {
        self.appLink = appLink
    }

    /// The owner answer of the link the calls go over (``CloudLinkSession/ownerLink``).
    public var ownerLink: @Sendable () async -> Int? {
        { [appLink] in await appLink.ownerLink }
    }

    /// Whether the link says the machine is a teammate's: only names a refused start, never grants one. A
    /// teammate answer older than ``teammateRecheck`` is asked again first, with a fresh grant: the owner may
    /// have shared the machine since, and the carrier's held session keeps its first grant (cmux#40201 F1).
    /// So a Retry reads the current grant, while a start right after the link answered asks nothing more.
    public var teammate: @Sendable () async -> Bool {
        { [appLink] in
            guard await appLink.callerIsTeammate else { return false }
            await appLink.regrant(unlessAnsweredWithin: Self.teammateRecheck)
            return await appLink.callerIsTeammate
        }
    }

    /// How old a teammate answer may be before ``teammate`` asks for a fresh grant.
    static let teammateRecheck: Duration = .seconds(5)
}
