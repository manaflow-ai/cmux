import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextHistory
import CmuxNextHistoryDaemon
import Foundation
import Testing

/// A daemon answers `history.entries.list` before its fold of the session journal is at the head: it gives the
/// agent sessions the fold has reached and names `agent` in `pending_kinds`. The vault and resume by id read
/// the agent sessions from that list (`history-agent-sessions-v1`), so a list that is not complete must never
/// read as the whole list: no row goes away, a session that is not in it is "still loading" and not "gone", and
/// the vault reads again while it shows.
@MainActor @Suite(.serialized) struct AgentSessionsPendingTests {
    /// The source's answer to each read in turn (the last one stays for the reads after it). Its wait returns at
    /// once and keeps the `reads` the vault gave it.
    @MainActor private final class Source: VaultSessionSource {
        var answers: [(sessions: [AgentSession], complete: Bool)]
        private(set) var refreshes = 0
        private(set) var waits: [Int] = []
        /// Runs in each wait, with the count of the reads before it.
        var onWait: (Int) -> Void = { _ in }
        /// The source's first answer is on its way and nothing says that it is slow.
        var startsQuietly = false
        /// The source can answer a read now.
        var answersNow = true
        private var held: (sessions: [AgentSession], complete: Bool) = ([], true)
        init(_ answers: [(sessions: [AgentSession], complete: Bool)]) { self.answers = answers }
        func refresh() async {
            held = answers[min(refreshes, answers.count - 1)]
            refreshes += 1
        }
        func sessions() -> [AgentSession] { held.sessions }
        func isLive(_ session: AgentSession) -> Bool { false }
        var isComplete: Bool { held.complete }
        func waitForPending(afterReads reads: Int) async throws {
            waits.append(reads)
            onWait(reads)
        }
    }

    /// A vault over `source`. `onScreen`: what its one surface answers; nil for a vault with no surface.
    private static func vault(_ source: Source, onScreen: Bool?) -> (AppServices, SessionVault) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let vault = SessionVault(source: source, copyText: { _ in }, openURL: { _ in })
        if let onScreen { vault.addSurface { onScreen } }
        services.vault = vault
        return (services, vault)
    }

    private static func refusal(_ services: AppServices, session: String) -> (reason: String, isNotFound: Bool)? {
        services.registry.capturingTypedRefusal {
            services.registry.perform("vaultCopyResumeCommand", invocation: ActionInvocation(arguments: ["session": .string(session)]))
        }
    }

    @Test func aVaultOnScreenReadsAListThatIsNotCompleteAgainUntilItIsComplete() async {
        let (old, new) = (SessionVaultTests.session("s-old", minutesAgo: 60), SessionVaultTests.session("s-new"))
        let source = Source([([old], false), ([old], false), ([new, old], true)])
        let (_, vault) = Self.vault(source, onScreen: true)
        await vault.reload()
        #expect(source.refreshes == 3, "the vault reads again until the list is complete")
        #expect(source.waits == [1, 2], "one wait before each read after the first, with the count of the reads before it")
        #expect(vault.rows.map(\.session.sessionID) == ["s-new", "s-old"])
        #expect(!vault.isPartial)
        #expect(!vault.isLoading)
    }

    @Test func aVaultThatIsNotOnScreenReadsOneTimeAndItsNextShowReadsAgain() async {
        let source = Source([([SessionVaultTests.session("s-old")], false)])
        for onScreen: Bool? in [false, nil] {
            let before = source.refreshes
            let (_, vault) = Self.vault(source, onScreen: onScreen)
            await vault.reload()
            #expect(source.refreshes == before + 1, "a hidden vault reads one time")
            #expect(source.waits.isEmpty, "and waits for nothing")
            #expect(vault.isPartial, "the list still says that it is not complete")
            #expect(vault.rows.map(\.session.sessionID) == ["s-old"], "with the rows that came")
            await vault.reload()
            #expect(source.refreshes == before + 2, "the next show is one read more")
        }
    }

    /// What the vault's one surface answers; a test changes it.
    @MainActor private final class Screen { var shows = false }

    /// Lets the main actor's waiting tasks run until `done`, for at most 2,000 turns.
    private static func turns(until done: () -> Bool) async {
        for _ in 0..<2_000 where !done() { await Task.yield() }
    }

    /// A window that comes out of the Dock, or shows again after Hide, gives the vault's view no sign: the view
    /// stays in its window and no view is hidden. The sign that the app gets is the window's (its occlusion state
    /// changed). The reads of a list that is not complete ended when the surface left the screen, so they start
    /// again at that sign: only while a surface shows the list, and only for a list that is not complete.
    @Test func aWindowThatComesBackOnScreenStartsTheReadsOfAListThatIsNotCompleteAgain() async throws {
        let (old, new) = (SessionVaultTests.session("s-old", minutesAgo: 60), SessionVaultTests.session("s-new"))
        let source = Source([([old], false), ([old], false), ([new, old], true)])
        let (services, vault) = Self.vault(source, onScreen: nil)
        let screen = Screen()
        vault.addSurface { screen.shows }
        await vault.reload()
        #expect(source.refreshes == 1, "a vault that is off screen reads one time")
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"vault-back-on-screen","workspace_key":"vb1"}"#.utf8))
        let controller = WindowController(state: WindowState(record: record), services: services, frame: NSRect(x: 200, y: 200, width: 900, height: 600))
        let changed = Notification(name: NSWindow.didChangeOcclusionStateNotification, object: controller.window)
        // The window's state changes and the surface stays off screen (the window goes into the Dock).
        controller.windowDidChangeOcclusionState(changed)
        await Self.turns { false }
        #expect(source.refreshes == 1, "nothing is read while no surface shows the list")
        // The window is back. AppKit can send the change more than one time: it is one reload.
        screen.shows = true
        controller.windowDidChangeOcclusionState(changed)
        controller.windowDidChangeOcclusionState(changed)
        await Self.turns { !vault.isPartial }
        #expect(source.refreshes == 3, "the reads start again and go on until the list is complete")
        #expect(source.waits == [1], "with the source's wait before each read after the first of that reload")
        #expect(vault.rows.map(\.session.sessionID) == ["s-new", "s-old"])
        #expect(!vault.isPartial)
        // A complete list is not read again at the window's next change.
        controller.windowDidChangeOcclusionState(changed)
        await Self.turns { false }
        #expect(source.refreshes == 3, "a complete list is not read again")
    }

    /// The window goes into the Dock while the reads go on: they end at the next wait, and the window's return
    /// starts them again.
    @Test func aSurfaceThatLeavesTheScreenDuringTheReadsEndsThemAndTheWindowsReturnStartsThemAgain() async throws {
        let (old, new) = (SessionVaultTests.session("s-old", minutesAgo: 60), SessionVaultTests.session("s-new"))
        let source = Source([([old], false), ([old], false), ([old], false), ([new, old], true)])
        let (services, vault) = Self.vault(source, onScreen: nil)
        let screen = Screen()
        screen.shows = true
        vault.addSurface { screen.shows }
        source.onWait = { reads in if reads == 2 { screen.shows = false } }
        await vault.reload()
        #expect(source.refreshes == 2, "the reads end when the surface leaves the screen")
        #expect(source.waits == [1, 2], "at the wait in which it left")
        #expect(vault.isPartial)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"vault-leaves","workspace_key":"vb3"}"#.utf8))
        let controller = WindowController(state: WindowState(record: record), services: services, frame: NSRect(x: 200, y: 200, width: 900, height: 600))
        let changed = Notification(name: NSWindow.didChangeOcclusionStateNotification, object: controller.window)
        controller.windowDidChangeOcclusionState(changed)
        await Self.turns { false }
        #expect(source.refreshes == 2, "nothing is read while the surface is off screen")
        screen.shows = true
        controller.windowDidChangeOcclusionState(changed)
        await Self.turns { !vault.isPartial }
        #expect(source.refreshes == 4, "the window's return starts the reads again, to the complete list")
        #expect(source.waits == [1, 2, 1])
        #expect(vault.rows.map(\.session.sessionID) == ["s-new", "s-old"])
    }

    /// A reload that ended at the bound of reads waits for the person's reload, as before: a window is covered and
    /// shown many times an hour, and a daemon that stays behind must not get 40 reads at each one.
    @Test func aWindowThatComesBackOnScreenStartsNoReadAfterAReloadThatEndedAtTheBound() async throws {
        let source = Source([([SessionVaultTests.session("s-old")], false)])
        let (services, vault) = Self.vault(source, onScreen: true)
        await vault.reload()
        #expect(source.refreshes == 40, "the reads end at the bound")
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"vault-bound","workspace_key":"vb2"}"#.utf8))
        let controller = WindowController(state: WindowState(record: record), services: services, frame: NSRect(x: 200, y: 200, width: 900, height: 600))
        controller.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: controller.window))
        await Self.turns { false }
        #expect(source.refreshes == 40, "the window's change starts no read: the bound waits for the person's reload")
        #expect(vault.isPartial)
        await vault.reload()
        #expect(source.refreshes == 80, "the person's reload reads again")
    }

    @Test func afterTheBoundAnIdThatIsNotInTheListIsStillLoadingAndTheNextReloadReadsAgain() async {
        let source = Source([([SessionVaultTests.session("s-old")], false)])
        let (services, vault) = Self.vault(source, onScreen: true)
        await vault.reload()
        #expect(source.refreshes == 40, "a daemon that stays behind is read 40 times, then the reads end")
        #expect(source.waits == Array(1...39))
        #expect(vault.isPartial, "the list still says that it is not complete")
        #expect(!vault.isLoading, "and the person can ask for a read")
        // A row action on a session that is not in the list: it can exist, so it is not "no session".
        let pending = Self.refusal(services, session: "s-newer")
        #expect(pending?.reason == HistoryAppStrings.stillLoading)
        #expect(pending?.isNotFound == false)
        // A session that is in the list acts, also while the list is not complete.
        #expect(Self.refusal(services, session: "s-old")?.reason == nil)
        await vault.reload()
        #expect(source.refreshes == 80, "the next reload reads again")
        // Only a complete list says that a session does not exist.
        source.answers = [([SessionVaultTests.session("s-old")], true)]
        await vault.reload()
        #expect(!vault.isPartial)
        let gone = Self.refusal(services, session: "s-newer")
        #expect(gone?.reason == HistoryAppStrings.noSession)
        #expect(gone?.isNotFound == true)
    }

    /// The wire link: `pending_kinds` with `agent` in the daemon's answer is a list of agent sessions that is not complete.
    @Test func theDaemonsAnswerSaysWhetherItsAgentSessionsAreTheWholeList() throws {
        func isComplete(_ answer: String) throws -> Bool {
            try JSONDecoder().decode(DaemonHistoryList.self, from: Data(answer.utf8)).agentSessions(machine: "local").isComplete
        }
        #expect(try !isComplete(#"{"entries":[],"pending_kinds":["agent"]}"#), "the fold of the agent sessions is behind")
        #expect(try isComplete(#"{"entries":[],"pending_kinds":["closed"]}"#), "another kind that is behind does not hold the agent sessions")
        #expect(try isComplete(#"{"entries":[]}"#), "a daemon that names no pending kind gave its whole list")
    }

    /// The daemon's fold goes from the oldest record to the newest, so the list of a fold that is behind is short.
    @Test func aListThatIsNotCompleteTakesNoSessionAway() {
        let old = SessionVaultTests.session("s-old", minutesAgo: 60), new = SessionVaultTests.session("s-new", minutesAgo: 30)
        var machine = MachineAgentSessions(machine: "local", listed: [new, old])
        #expect(machine.isComplete)
        let later = SessionVaultTests.session("s-old", minutesAgo: 1)
        machine.take(listed: [later], complete: false)
        #expect(machine.sessions.map(\.sessionID) == ["s-old", "s-new"], "the session that the short list does not have stays")
        #expect(machine.sessions.first?.lastActivityAt == later.lastActivityAt, "a session of the short list is the daemon's newer one")
        #expect(!machine.isComplete)
        // The whole list is the daemon's answer: a session that it does not have is gone.
        machine.take(listed: [later], complete: true)
        #expect(machine.sessions.map(\.sessionID) == ["s-old"])
        #expect(machine.isComplete)
    }

    /// The sessions of all machines are one list (the vault, the agents palette page, resume by id): newest
    /// activity first over all machines, minus the sessions that Clear History or Remove from History hid.
    @Test func theSessionsOfAllMachinesAreOneListNewestFirstMinusTheHiddenOnes() {
        let other = AgentSession(machine: "mini", provider: "codex", sessionID: "s-other", startedAt: Date(timeIntervalSinceNow: -120),
                                 lastActivityAt: Date(timeIntervalSinceNow: -120))
        let local = [SessionVaultTests.session("s-old", minutesAgo: 3), SessionVaultTests.session("s-new", minutesAgo: 1),
                     SessionVaultTests.session("s-hidden", minutesAgo: 0.5)]
        let machines = [MachineAgentSessions(machine: "local", listed: local), MachineAgentSessions(machine: "mini", listed: [other])]
        var hidden = HiddenHistory()
        hidden.hide(entry: "local/claude/s-hidden")
        #expect(machines.sessions(minus: hidden).map(\.sessionID) == ["s-new", "s-other", "s-old"])
        #expect(machines.sessions(minus: HiddenHistory()).map(\.sessionID) == ["s-hidden", "s-new", "s-other", "s-old"])
    }

    /// A machine that gave no answer yet has no list, so its list is not the whole list. Its first answer, an
    /// empty one too, is.
    @Test func aMachineThatGaveNoAnswerYetHasNoCompleteList() {
        var machine = MachineAgentSessions(machine: "cloud-1")
        #expect(!machine.isComplete, "no answer yet: a session can exist on that machine")
        #expect(machine.sessions.isEmpty)
        machine.take(listed: [], complete: true)
        #expect(machine.isComplete, "the daemon's own answer is the whole list, an empty one too")
        #expect(MachineAgentSessions(machine: "cloud-2", listed: []).isComplete)
        #expect(MachineAgentSessions(fold: AgentSessionFold(machine: "old-1")).isComplete, "a fold of an older daemon's journal is its answer")
    }

    /// This Mac's daemon is not connected yet: its start can take minutes while it builds its registry again. It
    /// gave no answer, so the app holds no whole list: resume by id says "still loading" and not "no session",
    /// and the vault shows its "not complete" mark and not its "no sessions yet" text.
    @Test func whileThisMacsDaemonGaveNoAnswerYetNoSessionIsSaidToNotExist() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let local = services.machines.local
        if case .connected = local.store.connectionState { Issue.record("the test's daemon must not be connected") }
        let work = services.registry.capturingWork {
            services.registry.perform("history.resumeAgentSession", invocation: ActionInvocation(arguments: ["session": .string("s-any")]))
        }
        let pending = try #require(await work.first?.value, "an id that no list has resumed something")
        #expect(pending.message == HistoryAppStrings.stillLoading, "a daemon that gave no answer cannot say that a session does not exist")
        #expect(pending.refusal == .unavailable)
        #expect(!services.history.agents.isComplete)
        // The vault over the app's own source: its one read gets no answer, and it says that the list is not complete.
        await services.vault.reload()
        #expect(services.vault.isPartial, "the vault shows its mark, not the text of an empty list")
        #expect(services.vault.rows.isEmpty)
        // The daemon's first answer, an empty list: now the session does not exist.
        var machine = try #require(services.history.agents.machines[local.machineID], "the read kept that this Mac's daemon gave no answer")
        machine.take(listed: [], complete: true)
        services.history.agents.machines[local.machineID] = machine
        #expect(services.history.agents.isComplete)
        await services.vault.reload()
        #expect(!services.vault.isPartial)
    }

    /// A healthy start: this Mac's daemon connects, and its first answer comes some hundred ms later. Words that
    /// show and go at each start are a flash, and the text of an empty list is false, so the vault shows neither.
    /// The words wait for a state that says that the daemon is slow or down: a restore reported, failed, dropped.
    @Test func theVaultsNotCompleteWordsWaitUntilTheDaemonIsSaidToBeSlowOrDown() async {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let local = services.machines.local
        await services.vault.reload()
        #expect(services.vault.isPartial, "no answer: the list is not complete, so the view shows no text of an empty list")
        #expect(!services.vault.showsNotCompleteMark, "the daemon connects and nothing says that it is slow: no words")
        // The daemon reports that it restores (its start builds the registry again): the words show, and go with the report.
        local.recovery.noteRestoring(RestoreProgressReport(session: "cmux-app", pid: 4242, waitedMs: 5_000, updatedAt: Date()))
        #expect(services.vault.showsNotCompleteMark, "a daemon that restores is slow: the words show")
        local.recovery.noteRestoring(nil)
        #expect(!services.vault.showsNotCompleteMark)
        // The startup deadline passes with no answer, no report and no failure: the store still says "connecting".
        local.startupClock = DeadlineNowClock()
        local.armStartupDeadline()
        for await unavailable in ObservationStream({ local.startup.isUnavailable }) where unavailable { break }
        #expect(local.store.connectionState == .connecting)
        #expect(services.vault.showsNotCompleteMark, "the deadline passed: the daemon is slow, the words show")
        // The store says that the daemon failed.
        local.store.markFailed("no daemon")
        #expect(services.vault.showsNotCompleteMark, "a daemon that failed: the words show")
    }

    /// The vault's first read can be before the daemon's handshake: it asked no daemon. At the handshake the list
    /// is still "not complete" from that read, and the words would show until the next read ends and then go.
    /// They wait for a read that starts after the connection; a source that is slow or down shows them at once.
    @Test func aReadFromTheQuietStartShowsNoWordsWhenTheSourceConnectsUntilTheNextRead() async {
        let source = Source([([], false), ([], false), ([SessionVaultTests.session("s-new")], true), ([], false)])
        let (_, vault) = Self.vault(source, onScreen: nil)
        (source.startsQuietly, source.answersNow) = (true, false)
        await vault.reload()
        #expect(vault.isPartial)
        #expect(!vault.showsNotCompleteMark, "the quiet start: no words")
        (source.startsQuietly, source.answersNow) = (false, true)
        #expect(vault.isPartial, "no read was made since the connection")
        #expect(!vault.showsNotCompleteMark, "connected, and the last read asked no daemon: no words until the next read")
        await vault.reload()
        #expect(vault.showsNotCompleteMark, "a read after the connection says that the list is not complete: the words show")
        await vault.reload()
        #expect(!vault.isPartial)
        #expect(!vault.showsNotCompleteMark)
        // A read in a quiet start again, and then the source is slow or down (not connected): the words show at once.
        (source.startsQuietly, source.answersNow) = (true, false)
        await vault.reload()
        #expect(!vault.showsNotCompleteMark)
        source.startsQuietly = false
        #expect(vault.showsNotCompleteMark, "a source that is slow or down after a quiet read: the words show")
    }

    /// In the quiet start the vault on screen reads each second (the wait of no read of a daemon), not at 1, 2,
    /// 4 and 8 s: the list comes at most 1 s after the handshake. The reads after it wait 1, 2, 4 s again, and
    /// the reads of the quiet start count for the bound of one reload.
    @Test func inTheQuietStartEachWaitIsTheFirstOneAndTheWaitsStartAgainAfterTheHandshake() async {
        let new = SessionVaultTests.session("s-new")
        let source = Source([([], false), ([], false), ([], false), ([], false), ([], false), ([], false), ([new], true)])
        let (_, vault) = Self.vault(source, onScreen: true)
        (source.startsQuietly, source.answersNow) = (true, false)
        // The handshake comes in the wait after the fourth read.
        source.onWait = { _ in if source.refreshes == 4 { (source.startsQuietly, source.answersNow) = (false, true) } }
        await vault.reload()
        #expect(source.refreshes == 7)
        #expect(source.waits == [0, 0, 0, 0, 1, 2], "4 reads asked no daemon: each wait after them is the first one; then the daemon's waits from their start")
        #expect(vault.rows.map(\.session.sessionID) == ["s-new"])
        #expect(!vault.isPartial)

        let quiet = Source([([], false)])
        let (_, stays) = Self.vault(quiet, onScreen: true)
        (quiet.startsQuietly, quiet.answersNow) = (true, false)
        await stays.reload()
        #expect(quiet.refreshes == 40, "a quiet start that does not end holds no reader for ever")
        #expect(quiet.waits == Array(repeating: 0, count: 39))
    }

    /// The same with the app's own source and this Mac's daemon: the vault's read is before the handshake. Then the
    /// daemon is connected and lists agent sessions, and a read gets no answer from it (no connection object in
    /// this test): the list stays "not complete" and is not the whole, empty list ("No agent sessions yet").
    @Test func afterTheHandshakeTheVaultShowsNoWordsUntilItsNextReadAndADaemonWithNoAnswerHasNoWholeList() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let local = services.machines.local
        await services.vault.reload()
        #expect(services.vault.isPartial)
        #expect(!services.vault.showsNotCompleteMark, "the quiet start: no words")
        let json = #"{"app":"cmux-tui","protocol":1,"session":"quiet-start","generation":"g1","capabilities":[""#
            + DaemonHistoryClient.agentSessionsCapability + #""]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        local.store.noteHandshake(identity)
        local.store.connectionState = .connected(identity)
        #expect(!local.isStartingQuietly)
        #expect(services.vault.isPartial, "no read was made since the handshake")
        #expect(!services.vault.showsNotCompleteMark, "the handshake came after the vault's read: no words until the next read")
        await services.vault.reload()
        #expect(!services.history.agents.isComplete, "a connected daemon that lists sessions gave no answer: no whole list")
        #expect(services.vault.isPartial, "the view shows no text of an empty list")
        #expect(services.vault.showsNotCompleteMark, "a read after the connection got no whole list: the words show")
    }

    /// Resume by id (`history.resumeAgentSession {session}`) reads one time and answers at once.
    @Test func resumeByIdSaysStillLoadingForAnIdThatAListNotCompleteDoesNotHave() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        func resume(_ id: String) async -> ActionWorkFailure? {
            let work = services.registry.capturingWork {
                services.registry.perform("history.resumeAgentSession", invocation: ActionInvocation(arguments: ["session": .string(id)]))
            }
            #expect(work.count == 1)
            return await work.first?.value
        }
        var machine = MachineAgentSessions(machine: "local")
        machine.take(listed: [SessionVaultTests.session("s-old")], complete: false)
        services.history.agents.machines["local"] = machine
        let pending = try #require(await resume("s-newer"), "an id that the list does not have resumed something")
        #expect(pending.message == HistoryAppStrings.stillLoading)
        #expect(pending.refusal == .unavailable)

        machine.take(listed: [SessionVaultTests.session("s-old")], complete: true)
        services.history.agents.machines["local"] = machine
        let gone = try #require(await resume("s-newer"))
        #expect(gone.message == HistoryAppStrings.noSession, "only a complete list says that a session does not exist")
    }
}

/// A clock whose sleeps complete on the next task turn: the startup deadline passes at once.
private struct DeadlineNowClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant() }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until _: Instant, tolerance _: Duration?) async throws {}
}
