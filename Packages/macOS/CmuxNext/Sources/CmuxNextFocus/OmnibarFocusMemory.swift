/// Chrome's per-tab omnibox focus (`OmniboxEditModel::SaveStateToTab`, `RestoreState`): a browser
/// tab left while its address bar had the keyboard gets the address bar back when the user returns
/// to the tab (a tab click, a tab shortcut, a pane or workspace switch). A click in the tab's page,
/// or any other focus that lands on the tab, forgets it.
///
/// The focus core drops a chrome target when the selected tab changes (`addressBar` falls back to
/// `content`); the app's focus coordinator keeps this memory above it and, when ``note(_:before:after:)``
/// says so, queues ``returnEvent`` to ask for the address bar again once the tab is back.
///
/// ```swift
/// if memory.note(event, before: previous.resolved, after: reduced.resolved) {
///     queue.append(OmnibarFocusMemory.returnEvent)
/// }
/// ```
public nonisolated struct OmnibarFocusMemory: Sendable {
    /// Tabs whose address bar had the keyboard when the user left them.
    public private(set) var tabs: Set<String> = []
    /// ``returnEvent`` is queued and not yet reduced.
    private var returnQueued = false
    /// At most this many tabs are remembered.
    public static let limit = 64
    /// The event that asks for a remembered tab's address bar back.
    public static let returnEvent = FocusEvent.focusTarget(.addressBar, source: .programmatic)

    /// An empty memory.
    public init() {}

    /// Notes one reduction.
    ///
    /// - Parameters:
    ///   - event: The event just reduced.
    ///   - before: What had the keyboard before it.
    ///   - after: What has it now.
    /// - Returns: True when the reduction brought back a tab whose address bar had the keyboard:
    ///   the caller queues ``returnEvent``.
    public mutating func note(_ event: FocusEvent, before: FocusState.Resolved, after: FocusState.Resolved) -> Bool {
        if case .addressBar(_, let left) = before, after.tab != left {
            // Tabs of other workspaces stay remembered; a closed tab's id never
            // comes back, so past a bound one entry goes.
            if tabs.count >= Self.limit { tabs.removeFirst() }
            tabs.insert(left)
        }
        guard let tab = after.tab, tabs.contains(tab) else { return false }
        tabs.remove(tab)
        // Only a return to the tab restores: its page, reached from another
        // tab by a tab or pane change. A click in its page is the user's
        // choice (a responder report), and so is any other target there.
        guard case .browserPage = after, before.tab != tab, Self.isReturn(event) else { return false }
        returnQueued = true
        return true
    }

    /// Whether `event`, about to be reduced, is the ``returnEvent`` this memory asked for: its
    /// address-bar focus is a return to the tab, which brings the edit back as it was (Chrome
    /// `OmniboxViewViews::OnTabChanged` restores the saved selection) instead of selecting all.
    ///
    /// - Parameter event: The next event the coordinator reduces.
    /// - Returns: True once per queued ``returnEvent``.
    public mutating func takeReturn(_ event: FocusEvent) -> Bool {
        guard returnQueued, event == Self.returnEvent else { return false }
        returnQueued = false
        return true
    }

    private static func isReturn(_ event: FocusEvent) -> Bool {
        switch event {
        case .selectTab, .focusPane, .topology, .expect, .dragEnded, .overlayClosed, .windowKey: true
        default: false
        }
    }
}
