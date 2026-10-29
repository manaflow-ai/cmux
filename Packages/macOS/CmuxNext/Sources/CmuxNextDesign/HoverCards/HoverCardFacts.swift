/// What the single-card invariant (H1, plans/cmux-next/hovercards.md) reads of the hover cards: the live card
/// windows, whether the window shows a card, and what the machine and an owner say it shows. ``violations`` is the
/// pure check, so a test breaks the rule on hand-built facts.
public nonisolated struct HoverCardFacts: Hashable, Sendable, Codable {
    /// Card windows alive (`HoverCardPanel.liveInstances`).
    public var windows: Int
    /// The card window shows a card.
    public var showing: Bool
    /// The card window is on screen.
    public var panelVisible: Bool
    /// The target the machine shows, if any.
    public var machineTarget: String?
    /// An owner's card (`HoverCardCoordinator.owned`), if any.
    public var owned: String?

    public init(windows: Int, showing: Bool, panelVisible: Bool, machineTarget: String?, owned: String?) {
        self.windows = windows
        self.showing = showing
        self.panelVisible = panelVisible
        self.machineTarget = machineTarget
        self.owned = owned
    }

    /// H1: at most one card window exists and shows, and it shows what the machine or its owner says.
    public var violations: [String] {
        var bad: [String] = []
        if windows > 1 { bad.append("\(windows) hover card windows exist") }
        if showing, machineTarget == nil, owned == nil { bad.append("a card shows while the machine has none") }
        if owned != nil, let shown = machineTarget { bad.append("an owner's card and \(shown) share the window") }
        if !showing, let shown = machineTarget, !panelVisible { bad.append("the machine shows \(shown) but no card is on screen") }
        return bad
    }
}
