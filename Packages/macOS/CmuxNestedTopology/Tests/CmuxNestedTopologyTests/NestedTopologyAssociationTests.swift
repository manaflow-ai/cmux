import Testing
@testable import CmuxNestedTopology

@Suite("Nested topology association and title authority")
struct NestedTopologyAssociationTests {
    @Test("a successful heuristic association is not rewritten by later guesses")
    func heuristicRunsOncePerAssociationKey() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let original = fixture.pane(
            tabRawID: "tab-1",
            title: NestedNodeTitle(value: "First guess", authority: .inferred),
            associationAuthority: .heuristic,
            heuristicAlreadySatisfied: true
        )
        let snapshot = try fixture.snapshot(
            tabs: [
                fixture.tab("tab-1", order: 0),
                fixture.tab("tab-2", order: 1),
            ],
            panes: [original]
        )
        let laterGuess = fixture.pane(
            tabRawID: "tab-2",
            title: NestedNodeTitle(value: "Guessed again", authority: .inferred),
            associationAuthority: .heuristic,
            heuristicAlreadySatisfied: true
        )

        let result = try reducer.applying(
            fixture.event(.paneUpdated(node: laterGuess)),
            to: snapshot
        )

        #expect(result.panes[0].association.tabID == fixture.id("tab-1", kind: .tab))
        #expect(result.panes[0].association.heuristicAlreadySatisfied)
        #expect(result.panes[0].title == original.title)

        let providerTitle = NestedNodeTitle(value: "Provider title", authority: .provider)
        let titled = try reducer.applying(
            fixture.event(.paneUpdated(node: fixture.pane(
                tabRawID: "tab-2",
                title: providerTitle,
                associationAuthority: .heuristic,
                heuristicAlreadySatisfied: true
            ))),
            to: result
        )
        #expect(titled.panes[0].association.tabID == fixture.id("tab-1", kind: .tab))
        #expect(titled.panes[0].title == providerTitle)
    }

    @Test("a repeated heuristic update without a title preserves the existing title")
    func repeatedHeuristicWithoutTitlePreservesTitle() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let inferredTitle = NestedNodeTitle(value: "First guess", authority: .inferred)
        let original = fixture.pane(
            tabRawID: "tab-1",
            title: inferredTitle,
            associationAuthority: .heuristic,
            heuristicAlreadySatisfied: true
        )
        let snapshot = try fixture.snapshot(
            tabs: [
                fixture.tab("tab-1", order: 0),
                fixture.tab("tab-2", order: 1),
            ],
            panes: [original]
        )
        let repeatedGuess = fixture.pane(
            tabRawID: "tab-2",
            title: nil,
            associationAuthority: .heuristic,
            heuristicAlreadySatisfied: true
        )

        let result = try reducer.applying(
            fixture.event(.paneUpdated(node: repeatedGuess)),
            to: snapshot
        )

        #expect(result.panes[0].association.tabID == fixture.id("tab-1", kind: .tab))
        #expect(result.panes[0].association.heuristicAlreadySatisfied)
        #expect(result.panes[0].title == inferredTitle)
    }

    @Test("authoritative provider parentage can replace a prior heuristic")
    func providerParentageWins() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let original = fixture.pane(
            tabRawID: "tab-1",
            associationAuthority: .heuristic,
            heuristicAlreadySatisfied: true
        )
        let snapshot = try fixture.snapshot(
            tabs: [
                fixture.tab("tab-1", order: 0),
                fixture.tab("tab-2", order: 1),
            ],
            panes: [original]
        )
        let authoritative = fixture.pane(
            tabRawID: "tab-2",
            associationAuthority: .provider,
            heuristicAlreadySatisfied: false
        )

        let result = try reducer.applying(
            fixture.event(.paneUpdated(node: authoritative)),
            to: snapshot
        )

        #expect(result.panes[0].association.tabID == fixture.id("tab-2", kind: .tab))
        #expect(result.panes[0].association.authority == .provider)
        #expect(result.panes[0].association.heuristicAlreadySatisfied)
    }

    @Test("a new agent session gets a fresh one-shot association key")
    func sessionChangeInvalidatesHeuristicLock() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let original = fixture.pane(
            tabRawID: "tab-1",
            sessionID: "session-old",
            title: NestedNodeTitle(value: "Old guess", authority: .inferred),
            associationAuthority: .heuristic,
            heuristicAlreadySatisfied: true
        )
        let snapshot = try fixture.snapshot(
            tabs: [
                fixture.tab("tab-1", order: 0),
                fixture.tab("tab-2", order: 1),
            ],
            panes: [original]
        )
        let replacementSession = fixture.pane(
            tabRawID: "tab-2",
            sessionID: "session-new",
            title: NestedNodeTitle(value: "New guess", authority: .inferred),
            associationAuthority: .heuristic,
            heuristicAlreadySatisfied: true
        )

        let result = try reducer.applying(
            fixture.event(.paneUpdated(node: replacementSession)),
            to: snapshot
        )

        #expect(result.panes[0].association.key.sessionID == "session-new")
        #expect(result.panes[0].association.tabID == fixture.id("tab-2", kind: .tab))
        #expect(result.panes[0].title == replacementSession.title)
    }

    @Test("a superseded session heuristic cannot replay over the current session")
    func supersededSessionHeuristicIsRejected() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let snapshot = try fixture.snapshot(
            tabs: [
                fixture.tab("tab-1", order: 0),
                fixture.tab("tab-2", order: 1),
                fixture.tab("tab-3", order: 2),
            ],
            panes: [fixture.pane(
                tabRawID: "tab-1",
                sessionID: "session-a",
                associationAuthority: .heuristic,
                heuristicAlreadySatisfied: true
            )]
        )
        let sessionB = fixture.pane(
            tabRawID: "tab-2",
            sessionID: "session-b",
            associationAuthority: .heuristic,
            heuristicAlreadySatisfied: true
        )
        let afterSessionB = try reducer.applying(
            fixture.event(.paneUpdated(node: sessionB)),
            to: snapshot
        )
        let replayedSessionA = fixture.pane(
            tabRawID: "tab-3",
            sessionID: "session-a",
            order: 7,
            title: NestedNodeTitle(value: "Stale replay", authority: .provider),
            associationAuthority: .heuristic,
            heuristicAlreadySatisfied: true
        )

        let result = try reducer.applying(
            fixture.event(.paneUpdated(node: replayedSessionA)),
            to: afterSessionB
        )

        #expect(result.panes[0].association.key.sessionID == "session-b")
        #expect(result.panes[0].association.tabID == fixture.id("tab-2", kind: .tab))
        #expect(result.panes[0].order == sessionB.order)
        #expect(result.panes[0].title == sessionB.title)
    }

    @Test("a new session cannot downgrade provider-owned parentage to a heuristic")
    func sessionChangePreservesProviderParentage() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let snapshot = try fixture.snapshot(
            panes: [fixture.pane(
                tabRawID: "tab-1",
                sessionID: "session-old",
                associationAuthority: .provider
            )]
        )
        let newSessionGuess = fixture.pane(
            tabRawID: "tab-2",
            sessionID: "session-new",
            title: NestedNodeTitle(value: "New session", authority: .provider),
            associationAuthority: .heuristic,
            heuristicAlreadySatisfied: true
        )

        let result = try reducer.applying(
            fixture.event(.paneUpdated(node: newSessionGuess)),
            to: snapshot
        )

        #expect(result.panes[0].association.key.sessionID == "session-new")
        #expect(result.panes[0].association.tabID == fixture.id("tab-1", kind: .tab))
        #expect(result.panes[0].association.authority == .provider)
        #expect(!result.panes[0].association.heuristicAlreadySatisfied)
        #expect(result.panes[0].title == newSessionGuess.title)
    }

    @Test("a successful heuristic association drives focus and close cascades")
    func heuristicAssociationIsTopologyBearing() throws {
        let fixture = NestedTopologyTestFixture()
        let heuristicPane = fixture.pane(
            tabRawID: "tab-2",
            associationAuthority: .heuristic,
            heuristicAlreadySatisfied: true
        )
        let snapshot = try fixture.snapshot(
            tabs: [
                fixture.tab("tab-1", order: 0),
                fixture.tab("tab-2", order: 1),
            ],
            panes: [heuristicPane],
            focus: NestedTopologyFocus(
                workspaceID: fixture.id("workspace-1", kind: .workspace),
                tabID: fixture.id("tab-2", kind: .tab),
                paneID: heuristicPane.id,
                agentID: fixture.id("agent-1", kind: .agent)
            )
        )

        let result = try NestedTopologyReducer().applying(
            fixture.event(.nodeClosed(id: fixture.id("tab-2", kind: .tab))),
            to: snapshot
        )

        #expect(result.tabs.map(\.id.rawID) == ["tab-1"])
        #expect(result.panes.isEmpty)
        #expect(result.agents.isEmpty)
        #expect(result.focus == NestedTopologyFocus(
            workspaceID: fixture.id("workspace-1", kind: .workspace),
            tabID: nil,
            paneID: nil,
            agentID: nil
        ))
    }

    @Test("authoritative titles cannot be overwritten by inference")
    func titleAuthorityLock() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let original = fixture.pane(
            title: NestedNodeTitle(value: "Provider title", authority: .provider)
        )
        let snapshot = try fixture.snapshot(panes: [original])
        let inferred = fixture.pane(
            title: NestedNodeTitle(value: "Prompt guess", authority: .inferred)
        )

        let result = try reducer.applying(
            fixture.event(.paneUpdated(node: inferred)),
            to: snapshot
        )

        #expect(result.panes[0].title == original.title)
    }

    @Test("user title locks survive provider updates")
    func userTitleLock() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let userTitle = NestedNodeTitle(value: "My title", authority: .user)
        let snapshot = try reducer.applying(
            .user(nodeID: fixture.id("pane-1", kind: .pane), value: userTitle.value),
            to: fixture.snapshot()
        )
        let providerUpdate = fixture.pane(
            title: NestedNodeTitle(value: "Provider refresh", authority: .provider)
        )

        let result = try reducer.applying(
            fixture.event(.paneUpdated(node: providerUpdate)),
            to: snapshot
        )

        #expect(result.panes[0].title == userTitle)
    }

    @Test("provider inputs cannot assert host or user title locks")
    func providerCannotAssertLocalTitleAuthority() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let snapshot = try fixture.snapshot()

        #expect(throws: NestedTopologyError.invalidProviderTitleAuthority(
            node: fixture.id("pane-1", kind: .pane),
            authority: .host
        )) {
            try fixture.snapshot(panes: [fixture.pane(title: NestedNodeTitle(
                value: "Forged host lock",
                authority: .host
            ))])
        }
        #expect(throws: NestedTopologyError.invalidProviderTitleAuthority(
            node: fixture.id("pane-1", kind: .pane),
            authority: .user
        )) {
            try reducer.applying(
                fixture.event(.paneUpdated(node: fixture.pane(title: NestedNodeTitle(
                    value: "Forged user lock",
                    authority: .user
                )))),
                to: snapshot
            )
        }
    }

    @Test("provider titles replace unlocked inferred titles")
    func providerReplacesInference() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let snapshot = try fixture.snapshot(panes: [fixture.pane(
            title: NestedNodeTitle(value: "Guess", authority: .inferred)
        )])
        let providerTitle = NestedNodeTitle(value: "Canonical", authority: .provider)

        let result = try reducer.applying(
            fixture.event(.paneUpdated(node: fixture.pane(title: providerTitle))),
            to: snapshot
        )

        #expect(result.panes[0].title == providerTitle)
    }

    @Test("provider title absence clears unlocked titles across every node kind")
    func providerClearsUnlockedTitles() throws {
        let fixture = NestedTopologyTestFixture()
        let snapshot = try fixture.snapshot(
            workspaces: [fixture.workspace(title: NestedNodeTitle(
                value: "Workspace provider title",
                authority: .provider
            ))],
            tabs: [fixture.tab(title: NestedNodeTitle(
                value: "Tab guess",
                authority: .inferred
            ))],
            panes: [fixture.pane(title: NestedNodeTitle(
                value: "Pane provider title",
                authority: .provider
            ))],
            agents: [fixture.agent(title: NestedNodeTitle(
                value: "Agent guess",
                authority: .inferred
            ))]
        )

        let result = try NestedTopologyReducer().applying([
            fixture.event(.workspaceUpdated(node: fixture.workspace(title: nil))),
            fixture.event(.tabUpdated(node: fixture.tab(title: nil))),
            fixture.event(.paneUpdated(node: fixture.pane(title: nil))),
            fixture.event(.agentUpdated(node: fixture.agent(title: nil))),
        ], to: snapshot)

        #expect(result.workspaces[0].title == nil)
        #expect(result.tabs[0].title == nil)
        #expect(result.panes[0].title == nil)
        #expect(result.agents[0].title == nil)
    }

    @Test("provider title absence preserves host and user locks")
    func providerCannotClearLockedTitles() throws {
        let fixture = NestedTopologyTestFixture()
        let hostTitle = NestedNodeTitle(value: "Host lock", authority: .host)
        let userTitle = NestedNodeTitle(value: "User lock", authority: .user)
        let reducer = NestedTopologyReducer()
        var snapshot = try fixture.snapshot()
        let locks: [NestedTopologyTitleChange] = [
            .host(nodeID: fixture.id("workspace-1", kind: .workspace), value: hostTitle.value),
            .user(nodeID: fixture.id("tab-1", kind: .tab), value: userTitle.value),
            .host(nodeID: fixture.id("pane-1", kind: .pane), value: hostTitle.value),
            .user(nodeID: fixture.id("agent-1", kind: .agent), value: userTitle.value),
        ]
        for lock in locks {
            snapshot = try reducer.applying(lock, to: snapshot)
        }

        let result = try reducer.applying([
            fixture.event(.workspaceUpdated(node: fixture.workspace(title: nil))),
            fixture.event(.tabUpdated(node: fixture.tab(title: nil))),
            fixture.event(.paneUpdated(node: fixture.pane(title: nil))),
            fixture.event(.agentUpdated(node: fixture.agent(title: nil))),
        ], to: snapshot)

        #expect(result.workspaces[0].title == hostTitle)
        #expect(result.tabs[0].title == userTitle)
        #expect(result.panes[0].title == hostTitle)
        #expect(result.agents[0].title == userTitle)
    }

    @Test("resolved parentage stays stable when independent event batches are reordered")
    func shuffledBatchParentStability() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let original = fixture.pane(
            tabRawID: "tab-1",
            associationAuthority: .heuristic,
            heuristicAlreadySatisfied: true
        )
        let snapshot = try fixture.snapshot(
            tabs: [
                fixture.tab("tab-1", order: 0),
                fixture.tab("tab-2", order: 1),
            ],
            panes: [original]
        )
        let repeatedGuess = fixture.event(.paneUpdated(node: fixture.pane(
            tabRawID: "tab-2",
            associationAuthority: .heuristic,
            heuristicAlreadySatisfied: true
        )))
        let statusUpdate = fixture.event(.agentUpdated(node: fixture.agent(
            status: NestedAgentStatus(presentation: .done, providerRawValue: "done")
        )))

        let first = try reducer.applying([repeatedGuess, statusUpdate], to: snapshot)
        let second = try reducer.applying([statusUpdate, repeatedGuess], to: snapshot)

        #expect(first == second)
        #expect(first.panes[0].association.tabID == fixture.id("tab-1", kind: .tab))
    }
}
