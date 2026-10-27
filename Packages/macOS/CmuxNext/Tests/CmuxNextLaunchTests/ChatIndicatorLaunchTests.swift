import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The agent chat tabs' indicator watches at launch (p08-startup-097), through fake starts that stand in for the
/// acpmux connections: no watch connects before the first frame; right after it when an agent page or a window
/// shows them; after startup otherwise. The upload sweep is one afterStartup post on the files lane at bestEffort.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ChatIndicatorLaunchTests {
    private static let local = ["AgentTurnStates.start", "SidebarSessionTree.start", "SidebarChatHistory.start"]

    private static func launch(_ s: StartupTestScheduler, _ connects: Connects, shown: ChatIndicatorLaunch.Shown = .init()) -> ChatIndicatorLaunch {
        ChatIndicatorLaunch(startup: s.startup, starts: .init(
            turnStates: { connects.names.append("AgentTurnStates.start") },
            sessionTree: { connects.names.append("SidebarSessionTree.start") },
            chatHistory: { connects.names.append("SidebarChatHistory.start") },
            chiefTurnStates: { connects.names.append("ChiefTurnStates.start") },
            uploadSweep: {},
            shown: {
                connects.looks += 1
                return shown
            }
        ))
    }

    private static func records(_ s: StartupTestScheduler) -> [StartupTaskLog.Record] { s.startup.log.records }

    @Test func anAgentPageBeforeTheFirstFrameConnectsRightAfterIt() {
        let s = StartupTestScheduler(), connects = Connects()
        let launch = Self.launch(s, connects)
        launch.post()
        launch.pageShown()
        for _ in 0..<6 { s.fire() }
        #expect(connects.names.isEmpty, "no acpmux connect before the first frame")
        #expect(connects.looks == 0, "nothing looks at the windows before the first frame")
        s.startup.firstFrameCommitted()
        for _ in 0..<8 { s.fire() }
        #expect(connects.names == Self.local, "this Mac's watches right after the first frame, in order")
        #expect(s.startup.completion == nil, "they did not wait for startup to complete")
        #expect(!launch.chiefNeeded, "no Chief tab shows: its watch waits for startup")
        #expect(launch.started == Self.local)
    }

    @Test func aWindowThatShowsAChiefTabConnectsBothRightAfterTheFirstFrame() {
        let s = StartupTestScheduler(), connects = Connects()
        let launch = Self.launch(s, connects, shown: .init(indicators: true, chief: true))
        launch.post()
        s.fire()
        #expect(connects.names.isEmpty)
        s.startup.firstFrameCommitted()
        for _ in 0..<8 { s.fire() }
        #expect(connects.looks == 1, "one look at the windows")
        #expect(connects.names == Self.local + ["ChiefTurnStates.start"])
        #expect(launch.indicatorsNeeded && launch.chiefNeeded)
        #expect(s.startup.completion == nil)
    }

    @Test func withNothingShownEveryWatchWaitsForStartupAndRunsOnce() {
        let s = StartupTestScheduler(), connects = Connects()
        let launch = Self.launch(s, connects)
        launch.post()
        s.startup.firstFrameCommitted()
        for _ in 0..<6 { s.fire() }
        #expect(connects.looks == 1)
        #expect(connects.names.isEmpty, "a launch that shows no chat tab keeps the watches out of the first frames")
        s.complete()
        for _ in 0..<8 { s.fire() }
        #expect(Set(connects.names) == Set(Self.local + ["ChiefTurnStates.start"]))
        #expect(connects.names.count == 4, "each watch once")
    }

    @Test func theUploadSweepIsOneAfterStartupPostOnTheFilesLaneAtBestEffort() throws {
        let s = StartupTestScheduler(), connects = Connects()
        Self.launch(s, connects).post()
        let sweep = try #require(Self.records(s).first { $0.name.description == "AgentChatUploads.sweep" })
        #expect(sweep.priority == .afterStartup)
        #expect(sweep.destination == .lane(.files, .bestEffort))
        s.startup.firstFrameCommitted()
        for _ in 0..<4 { s.fire() }
        let held = try #require(Self.records(s).first { $0.name.description == "AgentChatUploads.sweep" })
        #expect(held.startNanos == nil, "the sweep does not run before startup completes")
        s.startup.beginQuit()
    }

    /// Several windows and pages ask before the first frame: one look queued, one record of it.
    @Test func looksAtTheWindowsAreOneQueuedPostAndNoneAfterStartup() {
        let s = StartupTestScheduler(), connects = Connects()
        let launch = Self.launch(s, connects)
        launch.post()
        launch.checkShown()
        launch.checkShown()
        #expect(Self.records(s).filter { $0.name.description == "ChatIndicators.shown" }.count == 1)
        s.complete()
        for _ in 0..<8 { s.fire() }
        let looks = connects.looks
        launch.checkShown()
        launch.pageShown()
        for _ in 0..<4 { s.fire() }
        #expect(connects.looks == looks, "no walk over the windows after startup completed")
        #expect(connects.names.count == 4, "a page after startup starts nothing twice")
    }

    @Test func quitConnectsNothing() {
        let s = StartupTestScheduler(), connects = Connects()
        let launch = Self.launch(s, connects, shown: .init(indicators: true, chief: true))
        launch.post()
        launch.pageShown()
        s.startup.beginQuit()
        s.complete()
        for _ in 0..<8 { s.fire() }
        #expect(connects.names.isEmpty)
        #expect(connects.looks == 0)
    }
}

@MainActor
private final class Connects {
    var names: [String] = []
    var looks = 0
}
