@testable import CmuxNextAgentLanes
import CmuxNextDesign
import CmuxNextWakeupsTestSupport
import Testing

@MainActor
struct RemoteMachinesConnectionQuietTests {
    private static func machine(_ online: Bool) -> RemoteMachinesSidebar.Machine {
        RemoteMachinesSidebar.machines(lanes: [RemoteMachinesSidebarTests.lane("chat", peer: "studio")],
                                      peers: [.init(name: "studio", connected: online)])[0]
    }

    @Test func cachedRowsSurviveABlipAndOnlyALastingDropShowsOffline() async throws {
        let clock = ManualClock()
        let presentation = RemoteMachinesConnectionPresentation(clock: clock)
        defer { presentation.stop() }
        var changes = 0
        let online = [Self.machine(true)], offline = [Self.machine(false)]
        #expect(presentation.update(online, onChange: {}) == online)
        #expect(presentation.update(offline, onChange: { changes += 1 }) == online)
        try await clock.waitForSleeper()
        clock.advance(by: NoticeTiming.connectionQuiet - .milliseconds(1))
        #expect(presentation.update(offline, onChange: { changes += 1 }) == online)
        #expect(changes == 0)
        clock.advance(by: .milliseconds(1))
        #expect(await PeerStatePushTests.settle { changes == 1 })
        let shown = presentation.update(offline, onChange: { changes += 1 })
        #expect(shown == offline)
        #expect(RemoteMachinesSidebarTests.rows(shown)[0].info.title == RemoteMachinesStrings.offline("studio"))
        #expect(changes == 1, "repeat observations do not restart or repeat the notice")
        #expect(presentation.update(online, onChange: {}) == online)
        #expect(presentation.update(offline, onChange: {}) == online, "a new drop gets a new quiet period")
    }

    @Test func recoveryAndRemovalCancelTheNotice() async throws {
        let clock = ManualClock()
        let presentation = RemoteMachinesConnectionPresentation(clock: clock)
        defer { presentation.stop() }
        var changes = 0
        let online = [Self.machine(true)], offline = [Self.machine(false)]
        _ = presentation.update(online, onChange: {})
        _ = presentation.update(offline, onChange: { changes += 1 })
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(2))
        #expect(presentation.update(online, onChange: {}) == online)
        clock.advance(by: NoticeTiming.connectionQuiet)
        #expect(changes == 0)
        _ = presentation.update(offline, onChange: { changes += 1 })
        #expect(presentation.update([], onChange: {}) == [])
        clock.advance(by: NoticeTiming.connectionQuiet)
        #expect(changes == 0)
    }

    @Test func initiallyUnknownPeerIsQuietAndStopDropsCachedContent() {
        let presentation = RemoteMachinesConnectionPresentation(clock: ManualClock())
        let offline = [Self.machine(false)]
        let quiet = presentation.update(offline, onChange: {})
        #expect(RemoteMachinesSidebarTests.rows(quiet)[0].info.title == "studio")
        #expect(quiet[0].chats.isEmpty)
        _ = presentation.update([Self.machine(true)], onChange: {})
        presentation.stop()
        #expect(presentation.update(offline, onChange: {})[0].chats.isEmpty)
        presentation.stop()
    }
}
