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
    ///   - chatCards: Client-side sessions inserted immediately after their bound terminal.
    ///   - localBrowser: The phone-local browser appended after the pane's mirrored cards.
    ///   - attentionFirst: Whether attention cards should be stably partitioned first.
    public init(
        layout: MobileWorkspaceLayout?,
        paneID: String,
        fallbackTerminals: [MobileTerminalPreview],
        chatCards: [PaneChatCardSnapshot] = [],
        localBrowser: PaneLocalBrowserCardSnapshot? = nil,
        attentionFirst: Bool
    ) {
        var macOrderedCards: [PaneTabStripCardSnapshot]
        if let pane = layout.flatMap({ Self.pane(id: paneID, in: $0.root) }) {
            macOrderedCards = Self.cards(tabs: pane.tabs, chatCards: chatCards)
            isDegraded = false
        } else {
            macOrderedCards = Self.cards(terminals: fallbackTerminals, chatCards: chatCards)
            isDegraded = true
        }
        if let localBrowser {
            macOrderedCards.append(Self.card(from: localBrowser))
        }

        guard attentionFirst else {
            cards = macOrderedCards
            return
        }
        cards = macOrderedCards.filter(\.needsAttention)
            + macOrderedCards.filter { !$0.needsAttention }
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

    private static func cards(
        tabs: [MobileWorkspaceTab],
        chatCards: [PaneChatCardSnapshot]
    ) -> [PaneTabStripCardSnapshot] {
        let chatsByTerminalID = Dictionary(grouping: chatCards, by: \.terminalID)
        return tabs.flatMap { tab in
            [card(from: tab)] + (chatsByTerminalID[tab.id] ?? []).map(card(from:))
        }
    }

    private static func cards(
        terminals: [MobileTerminalPreview],
        chatCards: [PaneChatCardSnapshot]
    ) -> [PaneTabStripCardSnapshot] {
        let chatsByTerminalID = Dictionary(grouping: chatCards, by: \.terminalID)
        return terminals.flatMap { terminal in
            [card(from: terminal)] + (chatsByTerminalID[terminal.id.rawValue] ?? []).map(card(from:))
        }
    }

    private static func card(from tab: MobileWorkspaceTab) -> PaneTabStripCardSnapshot {
        PaneTabStripCardSnapshot(
            id: tab.id,
            title: tab.name,
            kind: PaneTabCardKind(mirrored: tab.kind),
            isReady: tab.isReady,
            agentStatus: tab.agentStatus,
            hasUnread: tab.hasUnread
        )
    }

    private static func card(from terminal: MobileTerminalPreview) -> PaneTabStripCardSnapshot {
        PaneTabStripCardSnapshot(
            id: terminal.id.rawValue,
            title: terminal.name,
            kind: PaneTabCardKind.terminal,
            isReady: terminal.isReady,
            agentStatus: nil,
            hasUnread: false
        )
    }

    private static func card(from chat: PaneChatCardSnapshot) -> PaneTabStripCardSnapshot {
        PaneTabStripCardSnapshot(
            id: "chat:\(chat.id)",
            sourceID: chat.id,
            title: chat.title,
            kind: .agentChat,
            boundTerminalID: chat.terminalID,
            isReady: true,
            agentStatus: chat.agentStatus,
            hasUnread: false
        )
    }

    private static func card(from browser: PaneLocalBrowserCardSnapshot) -> PaneTabStripCardSnapshot {
        PaneTabStripCardSnapshot(
            id: "local-browser:\(browser.id)",
            sourceID: browser.id,
            title: browser.title,
            kind: .localBrowser,
            isReady: true,
            agentStatus: nil,
            hasUnread: false
        )
    }
}
