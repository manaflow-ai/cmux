public import CMUXMobileCore

/// Pure current-pane tab ordering derived from authoritative Mac topology.
public struct PaneTabStripProjection: Equatable, Sendable {
    /// Cards in the order currently requested by the attention-shelf setting.
    public let cards: [PaneTabStripCardSnapshot]
    /// Whether the layout was unavailable and the flat terminal fallback was used.
    public let isDegraded: Bool

    /// Creates a current-pane strip projection.
    ///
    /// With the attention shelf off, `cards` exactly preserves the pane's Mac
    /// order. With it on, attention cards form the first stable partition and
    /// all remaining cards form the second stable partition. No recency or
    /// selection state participates in ordering.
    /// - Parameters:
    ///   - layout: The latest authoritative Mac workspace layout.
    ///   - paneID: The pane entered from the miniature hub.
    ///   - fallbackTerminals: Legacy flat terminals used until layout is available.
    ///   - attentionFirst: Whether attention cards should be stably partitioned first.
    public init(
        layout: MobileWorkspaceLayout?,
        paneID: String,
        fallbackTerminals: [MobileTerminalPreview],
        attentionFirst: Bool
    ) {
        let macOrderedCards: [PaneTabStripCardSnapshot]
        if let pane = layout.flatMap({ Self.pane(id: paneID, in: $0.root) }) {
            macOrderedCards = pane.tabs.map(Self.card(from:))
            isDegraded = false
        } else {
            macOrderedCards = fallbackTerminals.map(Self.card(from:))
            isDegraded = true
        }

        guard attentionFirst else {
            cards = macOrderedCards
            return
        }
        cards = macOrderedCards.filter(PaneTabAttentionPredicate.needsAttention)
            + macOrderedCards.filter { !PaneTabAttentionPredicate.needsAttention($0) }
    }

    private static func pane(
        id: String,
        in node: MobileWorkspaceLayoutNode
    ) -> MobileWorkspacePane? {
        switch node {
        case .pane(let pane):
            pane.id == id ? pane : nil
        case .split(let split):
            pane(id: id, in: split.first) ?? pane(id: id, in: split.second)
        }
    }

    private static func card(from tab: MobileWorkspaceTab) -> PaneTabStripCardSnapshot {
        PaneTabStripCardSnapshot(
            id: tab.id,
            title: tab.name,
            kind: tab.kind,
            isReady: tab.isReady,
            agentStatus: tab.agentStatus,
            hasUnread: tab.hasUnread
        )
    }

    private static func card(from terminal: MobileTerminalPreview) -> PaneTabStripCardSnapshot {
        PaneTabStripCardSnapshot(
            id: terminal.id.rawValue,
            title: terminal.name,
            kind: .terminal,
            isReady: terminal.isReady,
            agentStatus: nil,
            hasUnread: false
        )
    }
}
