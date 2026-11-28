public import CmuxNextCloud
public import CmuxNextMobile

/// Reads the phone host's Cloud directory while preserving account and session identity
/// across actor hops. The App supplies registry lookups; phone-host mapping stays here.
@MainActor
public struct MobileCloudLinksReader<Session: AnyObject> {
    private let auth: CloudAuth
    private let identity: MacInstallIdentity
    private let sessions: () -> [Session]
    private let machine: (Session) -> (id: String, record: CloudMachine)
    private let link: (Session) -> CloudLinkSession
    private let current: (Session) -> Bool
    private let paid: () -> Bool

    public init(auth: CloudAuth, identity: MacInstallIdentity, sessions: @escaping () -> [Session],
                machine: @escaping (Session) -> (id: String, record: CloudMachine),
                link: @escaping (Session) -> CloudLinkSession, current: @escaping (Session) -> Bool,
                paid: @escaping () -> Bool) {
        self.auth = auth
        self.identity = identity
        self.sessions = sessions
        self.machine = machine
        self.link = link
        self.current = current
        self.paid = paid
    }

    public func read() async -> MobileHostCloudLinks {
        guard auth.isSignedIn, let user = auth.user?.id else { return MobileHostCloudLinks() }
        let selectedTeam = auth.teamID
        // The backend team in attention events is the install token claim, not a Stack team id.
        guard let token = try? await identity.installToken(),
              let team = MacInstallIdentity.team(ofToken: token) else { return MobileHostCloudLinks() }
        var result: [MobileHostCloudLink] = []
        for session in sessions() {
            guard !machine(session).record.isGoneForPhones else { continue }
            let carrier = link(session)
            let socket = await carrier.currentLinkSocket
            let value = machine(session)
            guard current(session), !value.record.isGoneForPhones else { continue }
            result.append(MobileHostCloudLink(machine: value.record, machineID: value.id, teamID: team,
                socket: socket, cachedOwner: carrier.ownership.callerOwnsVM, user: auth.platformUserID ?? user))
        }
        // An account transition during either actor hop invalidates the whole answer.
        guard auth.isSignedIn, auth.user?.id == user, auth.teamID == selectedTeam else { return MobileHostCloudLinks() }
        // No desktops: a phone has no carrier route to a Cloud desktop yet.
        return MobileHostCloudLinks(paid: paid(), desktops: false, links: result)
    }
}
