/// What one page is owed of ``AgentPaneLinkPlaces``: the whole list, or only the places whose title
/// changed since its last push (`linkPlacesChanged`), by id.
///
/// An agent's title spinner renames its tab several times a second. The whole list (up to
/// ``AgentPaneLinkPlaces/maximumPlaces`` places, about 500 KB of JSON with ~1,000 workspaces) went to
/// every shown page on each of those turns, and each page parsed it and built its map again on the
/// one renderer thread every agent page shares: the New Tab page's frames took 100-977 ms while 13
/// agents ran (Lawrence 2026-11-19, "typing here is very laggy"). A rename now costs the places it
/// renamed. A change that adds, drops or moves a place still owes the whole list.
struct AgentPaneLinkPlacesOwed: Equatable {
    /// Past this many renamed places the whole list costs about the same, and is sent instead.
    static let mostChanged = 256

    /// Whether the page needs the whole list.
    private(set) var whole: Bool
    /// The renamed places owed, by id (empty when ``whole``).
    private(set) var changed: Set<String> = []

    /// A page that has the list as of now owes nothing.
    static let current = AgentPaneLinkPlacesOwed(whole: false)
    /// A page that needs the whole list.
    static let wholeList = AgentPaneLinkPlacesOwed(whole: true)

    /// Adds a change of the list: `renamed` the places whose title (or workspace name) changed and
    /// nothing else, or nil for a change that adds, drops or moves places.
    mutating func note(renamed: [AgentPaneLinkPlaces.Place]?) {
        guard !whole else { return }
        guard let renamed else { return self = .wholeList }
        changed.formUnion(renamed.map(\.id))
        if changed.count > Self.mostChanged { self = .wholeList }
    }
}
