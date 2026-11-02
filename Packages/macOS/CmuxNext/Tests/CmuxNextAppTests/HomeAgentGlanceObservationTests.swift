import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextDaemon
import Observation
import Testing

/// The first-run Home list has one observation scope over all of the agent tabs. Keep that scope
/// limited to the fields its rows render: usage/detail changes are idle mirror traffic and must not
/// re-run the 400-tab projection.
@MainActor
struct HomeAgentGlanceObservationTests {
    private nonisolated final class Counter: @unchecked Sendable {
        var value = 0
    }

    private func fixture(count: Int = 400) -> ([TabModel], AgentTurnStateStore) {
        let turns = AgentTurnStateStore.shared
        turns.localHost = "install:home-glance-harness"
        let tabs = (0..<count).map { index -> TabModel in
            let session = "home-glance-\(index)"
            let ref = AgentSessionRef(host: turns.localHost!, session: session, harness: "claude")
            turns.apply(session: session, state: nil, lastMessage: nil, muted: false,
                        title: "Chat \(index)", detail: AgentChatDetail(model: "model", contextTokens: 1))
            var snapshot = TabSnapshot(surface: SurfaceID(rawValue: UInt64(index + 1)),
                                       tabResourceID: ResourceID(rawValue: "tab_home_glance_\(index)"),
                                       kind: .conversation, title: "")
            snapshot.conversation = ConversationTabRef(agentSession: ref)
            return TabModel(snapshot)
        }
        return (tabs, turns)
    }

    private func invalidations(_ read: () -> Void, mutate: () -> Void) -> Int {
        let counter = Counter()
        withObservationTracking(read) { counter.value += 1 }
        mutate()
        return counter.value
    }

    private func assertParity(_ tab: TabModel, workingOn: Bool) {
        DesignSettings.shared.statusIndicator.showsAgentWorkingOnTabs = workingOn
        let item = TabItemMapping.shared.item(tab, fallbackTitle: "Agent")
        let glance = TabItemMapping.shared.glance(tab, fallbackTitle: "Agent")
        #expect(glance.title == item.title)
        #expect(glance.status == item.status)
        #expect(glance.indicator == item.indicator)
        #expect(glance.style == item.busyStyle)
    }

    @Test func usageDetailDoesNotInvalidateTheFourHundredTabGlance() {
        let (tabs, turns) = fixture()
        defer {
            turns.clearLive()
            turns.localHost = nil
        }
        let before = invalidations({
            for tab in tabs { _ = TabItemMapping.shared.item(tab, fallbackTitle: "Agent") }
        }) {
            turns.apply(session: "home-glance-0", state: nil, lastMessage: nil, muted: false,
                        title: "Chat 0", detail: AgentChatDetail(model: "model", contextTokens: 2))
        }

        let after = invalidations({
            for tab in tabs { _ = TabItemMapping.shared.glance(tab, fallbackTitle: "Agent") }
        }) {
            turns.apply(session: "home-glance-1", state: nil, lastMessage: nil, muted: false,
                        title: "Chat 1", detail: AgentChatDetail(model: "model", contextTokens: 3))
        }

        #expect(before == 1)
        #expect(after == 0)
    }

    @Test func glanceMatchesStripForEveryTurnStateAndWorkingSetting() {
        let states: [AgentTurnState?] = [nil, .working, .needsInput, .failed, .lost, .done]
        let (tabs, turns) = fixture(count: states.count)
        let terminalSnapshot = TabSnapshot(surface: SurfaceID(rawValue: 10_001),
                                           tabResourceID: ResourceID(rawValue: "tab_home_glance_terminal"),
                                           kind: .pty, title: "Build")
        let terminal = TabModel(terminalSnapshot)
        terminal.titleActivity = .working
        let settings = DesignSettings.shared
        let originalWorkingOn = settings.statusIndicator.showsAgentWorkingOnTabs
        defer {
            settings.statusIndicator.showsAgentWorkingOnTabs = originalWorkingOn
            turns.clearLive()
            turns.localHost = nil
        }

        for workingOn in [false, true] {
            for (index, state) in states.enumerated() {
                turns.apply(session: "home-glance-\(index)", state: state, lastMessage: nil, muted: false,
                            title: "Chat \(index)", detail: AgentChatDetail(model: "model", contextTokens: 1))
                assertParity(tabs[index], workingOn: workingOn)
            }
            assertParity(terminal, workingOn: workingOn)
        }
    }

    @Test func titleAndStatusChangesInvalidateTheGlance() {
        let (tabs, turns) = fixture(count: 2)
        defer {
            turns.clearLive()
            turns.localHost = nil
        }

        let titleInvalidations = invalidations({
            _ = TabItemMapping.shared.glance(tabs[0], fallbackTitle: "Agent")
        }) {
            tabs[0].titleText = "Renamed"
        }
        let statusInvalidations = invalidations({
            _ = TabItemMapping.shared.glance(tabs[1], fallbackTitle: "Agent")
        }) {
            turns.apply(session: "home-glance-1", state: .working, lastMessage: nil, muted: false,
                        title: "Chat 1", detail: AgentChatDetail(model: "model", contextTokens: 1))
        }

        #expect(titleInvalidations == 1)
        #expect(statusInvalidations == 1)
    }
}
