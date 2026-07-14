import CMUXMobileCore
import Testing
@testable import CmuxMobileShellModel

@Suite struct PaneTabStripProjectionTests {
    @Test func attentionPredicateMatchesWaitingOrUnreadOnly() {
        #expect(PaneTabAttentionPredicate.needsAttention(card("waiting", agent: .needsInput)))
        #expect(PaneTabAttentionPredicate.needsAttention(card("bell", unread: true)))
        #expect(PaneTabAttentionPredicate.needsAttention(card("both", agent: .needsInput, unread: true)))
        #expect(!PaneTabAttentionPredicate.needsAttention(card("running", agent: .running)))
        #expect(!PaneTabAttentionPredicate.needsAttention(card("idle", agent: .idle)))
        #expect(!PaneTabAttentionPredicate.needsAttention(card("unknown", agent: .unknown)))
        #expect(!PaneTabAttentionPredicate.needsAttention(card("plain")))
    }

    @Test func attentionPartitionIsStableAndToggleOffRestoresExactMacOrder() {
        let tabs = [
            tab("a"),
            tab("b", unread: true),
            tab("c", agent: .needsInput),
            tab("d"),
            tab("e", unread: true),
        ]
        let layout = layout(tabs)

        let attention = PaneTabStripProjection(
            layout: layout,
            paneID: "pane",
            fallbackTerminals: [],
            attentionFirst: true
        )
        #expect(attention.cards.map(\.id) == ["b", "c", "e", "a", "d"])

        let restored = PaneTabStripProjection(
            layout: layout,
            paneID: "pane",
            fallbackTerminals: [],
            attentionFirst: false
        )
        #expect(restored.cards.map(\.id) == ["a", "b", "c", "d", "e"])
    }

    @Test func reorderPayloadReplacesStripWithNewMacOrder() {
        let first = PaneTabStripProjection(
            layout: layout([tab("one"), tab("two"), tab("three")]),
            paneID: "pane",
            fallbackTerminals: [],
            attentionFirst: false
        )
        let reordered = PaneTabStripProjection(
            layout: layout([tab("three"), tab("one"), tab("two")]),
            paneID: "pane",
            fallbackTerminals: [],
            attentionFirst: false
        )

        #expect(first.cards.map(\.id) == ["one", "two", "three"])
        #expect(reordered.cards.map(\.id) == ["three", "one", "two"])
    }

    @Test func projectionSelectsOnlyTheEnteredPane() {
        let root = MobileWorkspaceLayoutNode.split(MobileWorkspaceSplit(
            id: "root",
            orientation: .horizontal,
            ratio: 0.5,
            first: .pane(pane("left", tabs: [tab("left-a"), tab("left-b")])),
            second: .pane(pane("right", tabs: [tab("right-a"), tab("right-b")]))
        ))
        let projection = PaneTabStripProjection(
            layout: MobileWorkspaceLayout(workspaceID: "workspace", root: root, activePaneID: "left"),
            paneID: "right",
            fallbackTerminals: [],
            attentionFirst: false
        )

        #expect(projection.cards.map(\.id) == ["right-a", "right-b"])
    }

    @Test func visibleDemandContainsOnlyVisibleCards() {
        let cards = [card("one"), card("two"), card("three")]
        #expect(PaneTabStripPreviewDemand(
            cards: cards,
            visibleCardIDs: ["one", "three", "not-a-card"]
        ).surfaceIDs == ["one", "three"])
        #expect(PaneTabStripPreviewDemand(cards: cards, visibleCardIDs: []).surfaceIDs.isEmpty)
    }

    @Test func chatCardsFollowBoundTerminalInInputOrderAndWaitingNeedsAttention() {
        let chats = [
            PaneChatCardSnapshot(id: "chat-b", terminalID: "terminal", title: "Second", agentStatus: .needsInput),
            PaneChatCardSnapshot(id: "chat-a", terminalID: "terminal", title: "First", agentStatus: .running),
        ]
        let projection = PaneTabStripProjection(
            layout: layout([tab("terminal"), tab("other")]),
            paneID: "pane",
            fallbackTerminals: [],
            chatCards: chats,
            attentionFirst: false
        )

        #expect(projection.cards.map(\.id) == ["terminal", "chat:chat-b", "chat:chat-a", "other"])
        #expect(projection.cards[1].kind == .agentChat)
        #expect(PaneTabAttentionPredicate.needsAttention(projection.cards[1]))
    }

    @Test func browserKindsRemainDistinctAndOnlyTerminalsRequestGridDemand() {
        let projection = PaneTabStripProjection(
            layout: layout([tab("terminal"), tab("mac-browser", kind: .browser)]),
            paneID: "pane",
            fallbackTerminals: [],
            localBrowser: PaneLocalBrowserCardSnapshot(id: "phone-browser", title: "Phone"),
            attentionFirst: false
        )
        #expect(projection.cards.map(\.kind) == [.terminal, .mirroredBrowser, .localBrowser])
        #expect(PaneTabStripPreviewDemand(
            cards: projection.cards,
            visibleCardIDs: Set(projection.cards.map(\.id))
        ).surfaceIDs == ["terminal"])
    }

    @Test func visibilityReducerHandlesPaneInputScrollAndHandleEvents() {
        var state = PaneTabStripVisibilityState(isStripVisible: false)
        state.handle(.enteredPane)
        #expect(state.isStripVisible)
        state.handle(.terminalKeystroke)
        #expect(!state.isStripVisible)
        state.handle(.handleTapped)
        #expect(state.isStripVisible)
        state.handle(.terminalScrollBegan)
        #expect(!state.isStripVisible)
        state.handle(.handleDraggedUp)
        #expect(state.isStripVisible)
    }

    private func card(
        _ id: String,
        agent: MobileWorkspaceAgentStatus? = nil,
        unread: Bool = false
    ) -> PaneTabStripCardSnapshot {
        PaneTabStripCardSnapshot(
            id: id,
            title: id,
            kind: .terminal,
            isReady: true,
            agentStatus: agent,
            hasUnread: unread
        )
    }

    private func tab(
        _ id: String,
        kind: MobileWorkspaceTabKind = .terminal,
        agent: MobileWorkspaceAgentStatus? = nil,
        unread: Bool = false
    ) -> MobileWorkspaceTab {
        MobileWorkspaceTab(
            id: id,
            name: id,
            kind: kind,
            isActive: false,
            isReady: true,
            agentStatus: agent,
            hasUnread: unread
        )
    }

    private func pane(_ id: String, tabs: [MobileWorkspaceTab]) -> MobileWorkspacePane {
        MobileWorkspacePane(id: id, frame: .unit, tabs: tabs)
    }

    private func layout(_ tabs: [MobileWorkspaceTab]) -> MobileWorkspaceLayout {
        MobileWorkspaceLayout(
            workspaceID: "workspace",
            root: .pane(pane("pane", tabs: tabs)),
            activePaneID: "pane"
        )
    }
}
