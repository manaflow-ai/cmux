/// Home follows a teleported Chief with no step from the person (a963, 2026-11-03: "I ask you to
/// teleport somewhere and it just works"). Pure: the app passes where this Mac's Chief went
/// (``ChiefWhereabouts``, from its home's `moved.json`), the account's Chiefs and the host it can
/// open a Chief on; this decides which conversation Home's Chief is.
public nonisolated struct HomeChiefFollow: Equatable, Sendable {
    /// What Home shows for this Mac's Chief.
    public enum Target: Equatable, Sendable {
        /// The Chief runs on this Mac: the Engine row (`home.chiefEngine`) decides, as before.
        case unchanged
        /// The Chief runs elsewhere and Home opens it there: this conversation.
        case conversation(String)
        /// Moved to cmux Cloud, and the account's list does not name that Chief yet: not this Mac's.
        case waiting
        /// Moved to a host Home cannot open a Chief on: Home stays on this Mac's conversation,
        /// whose chip says where it is (the host name).
        case away(String)
    }

    public let target: Target

    /// - Parameters:
    ///   - whereabouts: Where this Mac's Chief went.
    ///   - chiefs: The account's Chiefs (`chief.list`).
    ///   - reachableHost: The host whose Chief Home can open (a Chief placed on a paired server):
    ///     its host name and that Chief's main conversation; nil when there is none.
    public init(whereabouts: ChiefWhereabouts, chiefs: [HomeChiefRecord], reachableHost: (host: String, conversation: String)?) {
        switch whereabouts.location {
        case .thisMac:
            target = .unchanged
        case .cloud:
            let moved = whereabouts.cloudAgentID.flatMap { agent in chiefs.first { $0.id == agent } }
            target = moved?.mainConversation.map(Target.conversation) ?? .waiting
        case .host(let host):
            if let reachableHost, ChiefLocation.hostName(reachableHost.host) == host {
                target = .conversation(reachableHost.conversation)
            } else {
                target = .away(host)
            }
        }
    }

    /// The conversation Home opens as the Chief, when the Chief moved somewhere Home reaches.
    public var conversation: String? {
        if case .conversation(let conversation) = target { return conversation }
        return nil
    }

    /// Whether Home prefers this Mac's Chief: the Engine row's answer (`engineDefault`) while it runs
    /// here; no once it answers from cmux Cloud or a host Home opens; yes while it is on a host Home
    /// cannot open (its conversation here says where it went).
    public func prefersLocal(_ engineDefault: Bool) -> Bool {
        switch target {
        case .unchanged: engineDefault
        case .conversation, .waiting: false
        case .away: true
        }
    }
}
