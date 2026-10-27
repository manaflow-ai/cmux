public import CmuxNextSettings

/// The New Tab page's Recently Closed list, encoded once for every page that shows it.
///
/// A change to the closed history reaches every open New Tab page. Each page used to build the
/// JSON (favicons as data URLs included) and its script text again, so one close cost work linear
/// in the open pages on the main thread. Build one ``AgentPaneClosedList`` per change and assign
/// it to every ``AgentPaneView``: the page event is made here, once.
public nonisolated struct AgentPaneClosedList: Equatable, Sendable {
    /// The newest items, at most ``AgentPaneClosedItem/maximumPushed``.
    public let items: [AgentPaneClosedItem]
    /// The `recentlyClosed` page event for the shared page host.
    public let event: AgentPageEvent

    /// The empty list a page starts with.
    public static let empty = AgentPaneClosedList([])

    /// Encodes the newest of `items` once.
    ///
    /// - Parameters:
    ///   - items: The closed items, newest first; only the first ``AgentPaneClosedItem/maximumPushed`` are kept.
    ///   - encode: The per-item encoding; tests pass a counting wrapper to prove each item encodes once.
    public init(_ items: [AgentPaneClosedItem], encode: (AgentPaneClosedItem) -> JSONValue = { $0.json }) {
        let kept = Array(items.prefix(AgentPaneClosedItem.maximumPushed))
        self.items = kept
        event = AgentPageEvent(kind: "recentlyClosed", value: .array(kept.map(encode)))
    }

    /// Two lists are equal when they hold the same items; the encodings follow from them.
    public static func == (lhs: AgentPaneClosedList, rhs: AgentPaneClosedList) -> Bool {
        lhs.items == rhs.items
    }
}
