import Foundation

/// What the footer's Live button shows and its menu lists (`presence.live`, off by default: RFD 0141 makes Live opt-in; Leo 2026-11-24: "an icon maybe toggle
/// somewhere omnipresent... say the bottom left of the sidebar area"). The App fills it from the settings, the
/// team's contacts and the live-teammate feed; the sidebar draws it.
public nonisolated struct SidebarLiveState: Equatable, Sendable {
    /// A teammate the menu lists: opening them opens their direct message.
    public struct Person: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        /// Live now: listed first, under "Teammates", with their live count in the tooltip.
        public var isLive: Bool

        public init(id: String, name: String, isLive: Bool) {
            self.id = id
            self.name = name
            self.isLive = isLive
        }
    }

    /// This Mac is live (`presence.live`): the button is accent-filled; off it is dimmed.
    public var isLive: Bool
    /// The team's people, live ones first.
    public var people: [Person]

    public init(isLive: Bool = false, people: [Person] = []) {
        self.isLive = isLive
        self.people = people
    }

    /// How many teammates are live, the tooltip's count.
    public var teammatesLive: Int { people.filter(\.isLive).count }

    /// The state for the team's `(id, name)` pairs: live ones first, then by name.
    public init(isLive: Bool, team: [(id: String, name: String)], liveIDs: Set<String>) {
        self.init(isLive: isLive, people: team.map { Person(id: $0.id, name: $0.name, isLive: liveIDs.contains($0.id)) }
            .sorted { ($0.isLive ? 0 : 1, $0.name) < ($1.isLive ? 0 : 1, $1.name) })
    }
}
