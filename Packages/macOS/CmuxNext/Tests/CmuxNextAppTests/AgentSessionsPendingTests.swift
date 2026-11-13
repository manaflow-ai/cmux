import AppKit
import CmuxNextActions
@testable import CmuxNextApp
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
        private var held: (sessions: [AgentSession], complete: Bool) = ([], true)
        init(_ answers: [(sessions: [AgentSession], complete: Bool)]) { self.answers = answers }
        func refresh() async {
            held = answers[min(refreshes, answers.count - 1)]
            refreshes += 1
        }
        func sessions() -> [AgentSession] { held.sessions }
        func isLive(_ session: AgentSession) -> Bool { false }
        var isComplete: Bool { held.complete }
        func waitForPending(afterReads reads: Int) async throws { waits.append(reads) }
    }

    /// A vault over `source`. `onScreen`: what its one surface answers; nil for a vault with no surface.
    private static func vault(_ source: Source, onScreen: Bool?) -> (AppServices, SessionVault) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let vault = SessionVault(source: source, copyText: { _ in }, openURL: { _ in })
        if let onScreen { vault.reads.addSurface { onScreen } }
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
        vault.reads.addSurface { screen.shows }
        await vault.reload()
        #expect(source.refreshes == 1, "a vault that is off screen reads one time")
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"vault-back-on-screen","workspace_key":"vb1"}"#.utf8))
        let controller = WindowController(state: WindowState(record: record), services: services, frame: NSRect(x: 200, y: 200, width: 900, height: 600))
        let changed = Notification(name: NSWindow.didChangeOcclusionStateNotification, object: controller.window)
        // The window's state changes and the surface stays off screen (the window goes into the Dock).
        controller.windowDidChangeOcclusionState(changed)
        await Self.turns { false }
        #expect(source.refreshes == 1, "nothing is read while no surface shows the list")
        // The window is back.
        screen.shows = true
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
