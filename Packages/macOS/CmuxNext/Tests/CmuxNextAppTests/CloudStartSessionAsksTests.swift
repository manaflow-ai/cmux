import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextSettings
@testable import CmuxNextApp
import Foundation
import Observation
import Testing

/// The agent ask behind `cmux cloud start-session` (Lawrence: "start new VMs from acp chat"): a
/// card in the agent's own chat that only the person's Start lets through, and the runs registry
/// that lets the same command again pick up a run that outlasted its caller's answer.
@MainActor @Suite(.serialized)
struct CloudStartSessionAsksTests {
    static let account: [String?] = ["user-1", "team-1"]
    static let asked = CloudStartSessionStrings.Asked(machine: "dev", agent: "claude", command: "cmux cloud start-session --target machine:vm-x --agent claude")
    static let forgotten = ActionFailure(message: CloudStartSessionStrings.accountChanged(Self.asked))

    // MARK: The card belongs to its ask until the run ends

    /// Cards shown in place of a chat page, the clicks a test sends them, and a signal per card shown.
    final class Cards {
        var shown: [String: [AgentPaneToolCard]] = [:]
        var answers: [String: AgentToolCards.Answer] = [:]
        let (events, event) = AsyncStream<(tab: String, state: AgentPaneToolCard.State)>.makeStream()

        deinit { event.finish() }

        func install(_ asks: CloudStartSessionAsks) {
            asks.present = { [unowned self] cards, tab, answer in
                shown[tab] = cards.isEmpty ? nil : cards
                answers[tab] = answer
                if let first = cards.first { event.yield((tab, first.state)) }
                return true
            }
        }

        /// Waits until an ask's card shows in `tab` (the ask reached its card). Other cards shown
        /// there before (a run's working or done card) are passed over.
        func shownIn(_ tab: String) async {
            for await shown in events where shown.tab == tab && shown.state == .ask { return }
        }

        func click(_ tab: String, _ action: String) { answers[tab]?("cloud-start-session-" + tab, action, nil) }
    }

    static func ask(_ asks: CloudStartSessionAsks, _ tab: String, now: @escaping @MainActor @Sendable () -> [String?] = { Self.account }) -> Task<UUID, any Error> {
        Task { try await asks.ask(tab: tab, text: "ask", asked: Self.asked, account: Self.account, now: now) }
    }

    @Test func aCardThatCannotShowStartsNothingAndLeavesNoAskOpen() async {
        let asks = CloudStartSessionAsks()
        for _ in 0..<2 {
            await #expect(throws: ActionFailure(message: CloudStartSessionStrings.noPage(Self.asked))) {
                try await asks.ask(tab: "tab-without-page", text: "ask", asked: Self.asked, account: Self.account, now: { Self.account })
            }
        }
        #expect(asks.owner(of: "tab-without-page") == nil)
    }

    @Test func theCardAsksWithStartAndNotNow() {
        let card = CloudStartSessionAsks.askCard(tab: "chat", text: "The agent asks to start a claude session on Cloud machine dev.")
        #expect(card.state == .ask)
        #expect(card.actions.map(\.id) == ["start", "notNow"])
        #expect(card.actions.map(\.title) == [CloudStartSessionStrings.start, CloudMoveAskStrings.notNow])
    }

    @Test func aSecondAskWhileTheFirstRunsNeverTakesItsCard() async throws {
        let asks = CloudStartSessionAsks(), cards = Cards()
        cards.install(asks)
        let first = Self.ask(asks, "chat-1")
        await cards.shownIn("chat-1")
        #expect(cards.shown["chat-1"]?.first?.state == .ask)
        cards.click("chat-1", "start")
        let token = try await first.value
        // Started: the run goes on, and the chat's card is still the first ask's.
        asks.show(tab: "chat-1", token: token, .working, "starting")
        await #expect(throws: ActionFailure(message: CloudStartSessionStrings.askOpen(Self.asked))) {
            _ = try await asks.ask(tab: "chat-1", text: "second", asked: Self.asked, account: Self.account, now: { Self.account })
        }
        #expect(cards.shown["chat-1"]?.first?.text == "starting")
        // Another ask's token changes nothing.
        asks.finish(tab: "chat-1", token: UUID(), failure: "not yours")
        #expect(cards.shown["chat-1"]?.first?.text == "starting")
        asks.finish(tab: "chat-1", token: token, failure: "Machine `dev` started but its agent didn't (x).")
        #expect(cards.shown["chat-1"]?.first?.state == .failed)
        #expect(asks.owner(of: "chat-1") == nil, "the chat may ask again")
        cards.click("chat-1", "dismiss")
        #expect(cards.shown["chat-1"] == nil)
    }

    @Test func notNowStartsNothingAndFreesTheChat() async throws {
        let asks = CloudStartSessionAsks(), cards = Cards()
        cards.install(asks)
        let ask = Self.ask(asks, "chat-2")
        await cards.shownIn("chat-2")
        cards.click("chat-2", "notNow")
        await #expect(throws: ActionFailure(message: CloudStartSessionStrings.declined(Self.asked))) { _ = try await ask.value }
        #expect(cards.shown["chat-2"] == nil)
        #expect(asks.owner(of: "chat-2") == nil)
    }

    @MainActor @Observable final class SignedIn {
        var account: [String?]
        init(_ account: [String?]) { self.account = account }
    }

    /// A sign-out or team switch while the card is open ends it: the run says so, and the chat may ask again.
    @Test func anAccountChangeEndsAnOpenCard() async throws {
        let asks = CloudStartSessionAsks(), cards = Cards()
        cards.install(asks)
        let signedIn = SignedIn(Self.account)
        let ask = Self.ask(asks, "chat-3", now: { signedIn.account })
        await cards.shownIn("chat-3")
        signedIn.account = ["user-1", "team-2"]
        await #expect(throws: ActionFailure(message: CloudStartSessionStrings.accountChanged(Self.asked))) { _ = try await ask.value }
        #expect(cards.shown["chat-3"] == nil)
        #expect(asks.owner(of: "chat-3") == nil)
    }

    /// The run of a cancelled ask (its account ended) leaves no card and no ask behind.
    @Test func aCancelledAskRemovesItsCard() async throws {
        let asks = CloudStartSessionAsks(), cards = Cards()
        cards.install(asks)
        let ask = Self.ask(asks, "chat-4")
        await cards.shownIn("chat-4")
        ask.cancel()
        await #expect(throws: CancellationError.self) { _ = try await ask.value }
        #expect(cards.shown["chat-4"] == nil)
        #expect(asks.owner(of: "chat-4") == nil)
    }

    /// ``CloudStartSessionAsks/endAll()`` (a sign-out or team switch): a card still asking ends its
    /// ask, and one whose run goes on says the run stopped.
    @Test func endAllEndsAnAskingCardAndAStartedOne() async throws {
        let asks = CloudStartSessionAsks(), cards = Cards()
        cards.install(asks)
        let started = Self.ask(asks, "chat-5")
        await cards.shownIn("chat-5")
        cards.click("chat-5", "start")
        let token = try await started.value
        asks.show(tab: "chat-5", token: token, .working, "starting")
        let asking = Self.ask(asks, "chat-6")
        await cards.shownIn("chat-6")
        asks.endAll()
        await #expect(throws: ActionFailure(message: CloudStartSessionStrings.accountChanged(Self.asked))) { _ = try await asking.value }
        #expect(cards.shown["chat-6"] == nil)
        #expect(cards.shown["chat-5"]?.first?.state == .failed)
        #expect(cards.shown["chat-5"]?.first?.text == CloudStartSessionStrings.accountChangedWhileStarting(Self.asked))
        #expect(asks.owner(of: "chat-5") == nil && asks.owner(of: "chat-6") == nil)
    }

    /// A Start clicked just before the account ended, with the ask not yet resumed, starts
    /// nothing: the ask refuses as an account change and the card goes.
    @Test func aStartJustBeforeTheAccountEndedIsVoid() async throws {
        let asks = CloudStartSessionAsks(), cards = Cards()
        cards.install(asks)
        let ask = Self.ask(asks, "chat-7")
        await cards.shownIn("chat-7")
        // Both in one main-actor turn: the Start is the stream's first answer.
        cards.click("chat-7", "start")
        asks.endAll()
        await #expect(throws: ActionFailure(message: CloudStartSessionStrings.accountChanged(Self.asked))) { _ = try await ask.value }
        #expect(cards.shown["chat-7"] == nil)
        #expect(asks.owner(of: "chat-7") == nil)
    }

    // MARK: The asking chat links to the new one (#25597)

    /// A started run leaves a done card in the asking chat that links to the new chat: Open Chat
    /// shows it (and the card goes), Dismiss only removes the card, and the chat may ask again.
    @Test func aStartedRunLinksTheAskingChatToTheNewChat() async throws {
        let asks = CloudStartSessionAsks(), cards = Cards()
        cards.install(asks)
        let ask = Self.ask(asks, "chat-8")
        await cards.shownIn("chat-8")
        cards.click("chat-8", "start")
        let token = try await ask.value
        asks.show(tab: "chat-8", token: token, .working, "starting")
        var revealed = 0
        asks.started(tab: "chat-8", token: token, text: CloudStartSessionStrings.started(agent: "claude", machine: "dev"),
                     gone: CloudStartSessionStrings.chatGone(agent: "claude", machine: "dev")) {
            revealed += 1
            return true
        }
        let card = try #require(cards.shown["chat-8"]?.first)
        #expect(card.state == .done)
        #expect(card.text == CloudStartSessionStrings.started(agent: "claude", machine: "dev"))
        #expect(card.actions.map(\.id) == ["open", "dismiss"])
        #expect(card.actions.map(\.title) == [CloudStartSessionStrings.openChat, CloudMoveAskStrings.dismiss])
        #expect(asks.owner(of: "chat-8") == nil, "the chat may ask again")
        #expect(revealed == 0, "nothing is shown until the person clicks")
        cards.click("chat-8", "open")
        #expect(revealed == 1)
        #expect(cards.shown["chat-8"] == nil)
    }

    /// Open Chat when no connected machine lists the new chat any more says so, with Dismiss.
    @Test func openChatOnAClosedChatSaysItIsGone() async throws {
        let asks = CloudStartSessionAsks(), cards = Cards()
        cards.install(asks)
        let ask = Self.ask(asks, "chat-9")
        await cards.shownIn("chat-9")
        cards.click("chat-9", "start")
        let token = try await ask.value
        let gone = CloudStartSessionStrings.chatGone(agent: "claude", machine: "dev")
        asks.started(tab: "chat-9", token: token, text: "started", gone: gone) { false }
        cards.click("chat-9", "open")
        #expect(cards.shown["chat-9"]?.first?.state == .failed)
        #expect(cards.shown["chat-9"]?.first?.text == gone)
        #expect(cards.shown["chat-9"]?.first?.actions.map(\.id) == ["dismiss"])
        cards.click("chat-9", "dismiss")
        #expect(cards.shown["chat-9"] == nil)
    }

    /// Only the ask that owns the card turns it into the link, and a later ask in that chat
    /// owns the card from then on: the old link's buttons change nothing.
    @Test func theLinkBelongsToItsAskAndALaterAskTakesTheCard() async throws {
        let asks = CloudStartSessionAsks(), cards = Cards()
        cards.install(asks)
        let first = Self.ask(asks, "chat-10")
        await cards.shownIn("chat-10")
        cards.click("chat-10", "start")
        let token = try await first.value
        asks.show(tab: "chat-10", token: token, .working, "starting")
        asks.started(tab: "chat-10", token: UUID(), text: "not yours", gone: "") { true }
        #expect(cards.shown["chat-10"]?.first?.text == "starting")
        var revealed = 0
        asks.started(tab: "chat-10", token: token, text: "started", gone: "") {
            revealed += 1
            return true
        }
        let oldOpen = try #require(cards.answers["chat-10"])
        let second = Self.ask(asks, "chat-10")
        await cards.shownIn("chat-10")
        oldOpen("cloud-start-session-chat-10", "open", nil)
        #expect(revealed == 0)
        #expect(cards.shown["chat-10"]?.first?.state == .ask)
        cards.click("chat-10", "notNow")
        _ = try? await second.value
    }

    /// A sign-out or team switch removes a done card: its Open Chat would show a chat of the
    /// account that ended.
    @Test func endAllRemovesADoneCard() async throws {
        let asks = CloudStartSessionAsks(), cards = Cards()
        cards.install(asks)
        let ask = Self.ask(asks, "chat-11")
        await cards.shownIn("chat-11")
        cards.click("chat-11", "start")
        let token = try await ask.value
        asks.started(tab: "chat-11", token: token, text: "started", gone: "") { true }
        #expect(cards.shown["chat-11"]?.first?.state == .done)
        asks.endAll()
        #expect(cards.shown["chat-11"] == nil)
    }

    /// The page reads the done state by its name (toolCardStore.ts).
    @Test func aDoneCardGoesToThePageAsDone() {
        let card = AgentPaneToolCard(id: "c", state: .done, text: "t", actions: [])
        #expect(AgentPageEvent.toolCards([card]).value.compactText.contains("\"state\":\"done\""))
    }

    // MARK: A run that outlasts its caller's answer

    /// What the runs' work counts and the clock they read, shared with their closures.
    @MainActor final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    static let key = CloudStartSessionRuns.Key(machine: "name:dev", agent: "codex", cwd: nil, caller: "chat-9", account: Self.account)
    static let pending: CloudStartSessionRuns.Fields = ["pending": .bool(true)]
    /// A caller's wait that never ends by itself (the run's end cancels it).
    static let waits: @MainActor (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }

    static func answer(_ runs: CloudStartSessionRuns, key: CloudStartSessionRuns.Key = Self.key, within: Duration = .seconds(190),
                       _ work: @escaping @MainActor () async throws -> CloudStartSessionRuns.Fields) async throws -> CloudStartSessionRuns.Fields {
        try await runs.answer(key, within: within, pending: Self.pending, forgotten: Self.forgotten, work)
    }

    /// A caller that answered pending leaves nothing waiting on a run that never ends.
    @Test func aCallerThatAnsweredPendingHoldsNothingOnTheRun() async throws {
        let runs = CloudStartSessionRuns()
        runs.sleep = { _ in }
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        let answered = try await Self.answer(runs, within: .seconds(1)) {
            for await _ in gate { break }
            return ["session_id": .string("never")]
        }
        #expect(answered == Self.pending)
        #expect(runs.waitingCount == 0)
        #expect(runs.count == 1, "the run goes on")
        runs.forgetAll()
    }

    /// A sign-out or team switch answers a caller still waiting at once, and cancels its run.
    @Test func forgetAllAnswersAWaitingCallerAtOnce() async throws {
        let runs = CloudStartSessionRuns()
        let (waiting, wait) = AsyncStream<Void>.makeStream()
        defer { wait.finish() }
        runs.sleep = { _ in
            wait.yield()
            try? await Task.sleep(for: .seconds(3600))
        }
        // Never ends by itself: only the run's cancellation ends it.
        let (never, keep) = AsyncStream<Void>.makeStream()
        defer { keep.finish() }
        let caller = Task { @MainActor in
            try await Self.answer(runs) {
                for await _ in never { break }
                return ["session_id": .string("late")]
            }
        }
        for await _ in waiting { break }
        runs.forgetAll()
        await #expect(throws: Self.forgotten) { _ = try await caller.value }
        #expect(runs.count == 0)
        // The same ask after starts afresh.
        runs.sleep = Self.waits
        #expect(try await Self.answer(runs) { ["session_id": .string("new")] }["session_id"] == .string("new"))
    }

    /// A forget that lands after the caller's deadline fired, before the caller resumed, still
    /// refuses that caller: never `pending` for a run its account ended.
    @Test func aForgetAfterTheDeadlineStillRefusesTheCaller() async throws {
        let runs = CloudStartSessionRuns()
        // The forget is queued on the main actor before the deadline's own answer.
        runs.sleep = { [runs] _ in
            // task-owner: one-shot test step, ends at once
            Task { @MainActor in runs.forgetAll() }
        }
        let (never, keep) = AsyncStream<Void>.makeStream()
        defer { keep.finish() }
        await #expect(throws: Self.forgotten) {
            _ = try await Self.answer(runs, within: .seconds(1)) {
                for await _ in never { break }
                return ["session_id": .string("late")]
            }
        }
        #expect(runs.count == 0)
    }

    /// An end that lands as the caller's deadline fires reaches that caller (not pending), and the
    /// run is not kept: the caller saw it.
    @Test func anEndAtTheDeadlineReachesTheCaller() async throws {
        let runs = CloudStartSessionRuns()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (ending, ended) = AsyncStream<Void>.makeStream()
        defer { open.finish(); ended.finish() }
        // The deadline lets the run end, and fires once it has.
        runs.sleep = { _ in
            open.yield()
            for await _ in ending { break }
        }
        let fields = try await Self.answer(runs) {
            for await _ in gate { break }
            ended.yield()
            return ["session_id": .string("s")]
        }
        #expect(fields["session_id"] == .string("s"))
        #expect(runs.count == 0, "the caller saw it end, so it is not kept")
    }

    @Test func aRunItsCallerSawEndIsNotKept() async throws {
        let runs = CloudStartSessionRuns()
        runs.sleep = Self.waits
        let started = Box(0)
        let work: @MainActor () async throws -> CloudStartSessionRuns.Fields = {
            started.value += 1
            return ["session_id": .string("s-\(started.value)")]
        }
        #expect(try await Self.answer(runs, work)["session_id"] == .string("s-1"))
        #expect(runs.count == 0)
        #expect(try await Self.answer(runs, work)["session_id"] == .string("s-2"), "a new session, not the last one")
    }

    @Test func theSameAskWhileARunGoesOnWaitsForItAndTakesItsEnd() async throws {
        let runs = CloudStartSessionRuns()
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        let started = Box(0)
        let work: @MainActor () async throws -> CloudStartSessionRuns.Fields = {
            started.value += 1
            // A second start (the bug) answers at once: it never reads the first start's gate.
            guard started.value == 1 else { return ["session_id": .string("s-\(started.value)")] }
            for await _ in gate { break }
            return ["session_id": .string("s-1")]
        }
        // The first caller's wait ends at once: it answers pending, and the run goes on.
        runs.sleep = { _ in }
        #expect(try await Self.answer(runs, work) == Self.pending)
        // The second caller is waiting when its own wait begins: that lets the run end.
        runs.sleep = { _ in
            open.yield(())
            try? await Task.sleep(for: .seconds(3600))
        }
        #expect(try await Self.answer(runs, work)["session_id"] == .string("s-1"))
        #expect(started.value == 1)
        #expect(runs.count == 0, "it reached a caller, so it is not kept")
    }

    @Test func aRunEveryCallerLeftIsHandedToTheNextSameAskOnce() async throws {
        let runs = CloudStartSessionRuns()
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        let started = Box(0)
        let work: @MainActor () async throws -> CloudStartSessionRuns.Fields = {
            started.value += 1
            guard started.value == 1 else { return ["session_id": .string("s-\(started.value)")] }
            for await _ in gate { break }
            return ["session_id": .string("s-1")]
        }
        runs.sleep = { _ in }
        #expect(try await Self.answer(runs, work) == Self.pending)
        open.yield(())
        await runs.settled(Self.key)
        #expect(runs.count == 1, "nobody saw it end")
        runs.sleep = Self.waits
        #expect(try await Self.answer(runs, work)["session_id"] == .string("s-1"))
        #expect(started.value == 1)
        #expect(runs.count == 0, "handed out once")
    }

    @Test func aKeptRunExpiresForTheSameAsk() async throws {
        let runs = CloudStartSessionRuns()
        let clock = Box(ContinuousClock.now)
        runs.now = { clock.value }
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        runs.sleep = { _ in }
        _ = try await Self.answer(runs) {
            for await _ in gate { break }
            return ["session_id": .string("old")]
        }
        open.yield(())
        await runs.settled(Self.key)
        clock.value += CloudStartSessionRuns.kept + .seconds(1)
        runs.sleep = Self.waits
        let fresh = try await Self.answer(runs) { ["session_id": .string("new")] }
        #expect(fresh["session_id"] == .string("new"))
        #expect(runs.count == 0)
    }

    @Test func aFailedRunEveryCallerLeftIsHandedOutOnceToo() async throws {
        let runs = CloudStartSessionRuns()
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        let failure = ActionFailure(message: "Machine `dev` started but its agent didn't (x).")
        runs.sleep = { _ in }
        _ = try await Self.answer(runs) {
            for await _ in gate { break }
            throw failure
        }
        open.yield(())
        await runs.settled(Self.key)
        runs.sleep = Self.waits
        await #expect(throws: failure) { _ = try await Self.answer(runs) { ["session_id": .string("not reached")] } }
        #expect(runs.count == 0)
    }

    @Test func runsThatEndTogetherKeepAtMostTheLimit() async throws {
        let runs = CloudStartSessionRuns()
        runs.sleep = { _ in }
        let total = CloudStartSessionRuns.limit + 8
        let keys = (0..<total).map { CloudStartSessionRuns.Key(machine: "id:vm-\($0)", agent: "claude", cwd: nil, caller: nil, account: Self.account) }
        // One gate per run: a stream has one reader at a time.
        let gates = keys.map { _ in AsyncStream<Void>.makeStream() }
        defer { for gate in gates { gate.continuation.finish() } }
        for (key, gate) in zip(keys, gates) {
            _ = try await Self.answer(runs, key: key) {
                for await _ in gate.stream { break }
                return ["session_id": .string("s")]
            }
        }
        // Every caller answered pending; now every run ends.
        for gate in gates { gate.continuation.yield(()) }
        for key in keys { await runs.settled(key) }
        #expect(runs.keptCount <= CloudStartSessionRuns.limit)
    }

    /// Another account's same ask never takes a kept run's end.
    @Test func runsArePerAccount() async throws {
        let runs = CloudStartSessionRuns()
        let mine = Self.key
        var theirs = Self.key
        theirs.account = ["user-2", nil]
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        runs.sleep = { _ in }
        // Mine answers pending, then ends with nobody waiting: kept for my next ask.
        _ = try await Self.answer(runs, key: mine) {
            for await _ in gate { break }
            return ["session_id": .string("mine")]
        }
        open.yield()
        await runs.settled(mine)
        #expect(runs.keptCount == 1)
        runs.sleep = Self.waits
        let started = Box(0)
        let fields = try await Self.answer(runs, key: theirs) {
            started.value += 1
            return ["session_id": .string("theirs")]
        }
        #expect(fields["session_id"] == .string("theirs"))
        #expect(started.value == 1, "another account's ask ran its own start")
        #expect(runs.keptCount == 1, "mine is still kept for me")
        runs.forgetAll()
        #expect(runs.count == 0)
    }

    // MARK: One creation per new name

    enum CreationEvent: Equatable { case joined(String), entered(Int) }

    /// Two asks for one new name share one creation; another team's ask for it, meanwhile, makes its own.
    @Test func twoRunsForOneNewNameCreateOnce() async throws {
        let services = MachineIconTests.services()
        let session = MachineIconTests.cloudMachine(services, id: "vm-create-\(UUID().uuidString.prefix(8))")
        let runs = CloudStartSessionRuns()
        let (events, event) = AsyncStream<CreationEvent>.makeStream()
        runs.joinedCreation = { event.yield(.joined($0)) }
        // One gate per creation, each finished at the end: a second creation (the bug) never shares one.
        let gates = Box<[AsyncStream<Void>.Continuation]>([])
        defer { for gate in gates.value { gate.finish() }; event.finish() }
        let creates = Box(0)
        func create() -> @MainActor () async throws -> CloudMachineSession {
            let (gate, open) = AsyncStream<Void>.makeStream()
            gates.value.append(open)
            return {
                creates.value += 1
                event.yield(.entered(creates.value))
                for await _ in gate { break }
                return session
            }
        }
        // The next join or creation: a second creation (the bug) ends the wait as surely as the join.
        func next() async -> CreationEvent? {
            for await value in events { return value }
            return nil
        }
        let first = Task { @MainActor in try await runs.creating("dev", account: Self.account, create()) }
        #expect(await next() == .entered(1))
        let second = Task { @MainActor in try await runs.creating("dev", account: Self.account, create()) }
        #expect(await next() == .joined("dev"))
        let other = Task { @MainActor in try await runs.creating("dev", account: ["user-1", "team-2"], create()) }
        #expect(await next() == .entered(2), "another team's ask made its own machine while the first was being made")
        for gate in gates.value { gate.yield() }
        let one = try await first.value
        let two = try await second.value
        _ = try await other.value
        #expect(creates.value == 2)
        #expect(one === session && two === session)
    }

    /// A creation that ignores cancellation and finishes after a sign-out or team switch hands its
    /// machine to nobody: its asker and anyone who joined get `CancellationError`.
    @Test func aCreationThatEndsAfterForgetAllHandsOutNothing() async throws {
        let services = MachineIconTests.services()
        let session = MachineIconTests.cloudMachine(services, id: "vm-forgot-\(UUID().uuidString.prefix(8))")
        let runs = CloudStartSessionRuns()
        let (events, event) = AsyncStream<CreationEvent>.makeStream()
        runs.joinedCreation = { event.yield(.joined($0)) }
        defer { event.finish() }
        // Resumed only by the test, never by cancellation.
        let resume = Box<CheckedContinuation<Void, Never>?>(nil)
        let create: @MainActor () async throws -> CloudMachineSession = {
            await withCheckedContinuation { continuation in
                resume.value = continuation
                event.yield(.entered(1))
            }
            return session
        }
        func next() async -> CreationEvent? {
            for await value in events { return value }
            return nil
        }
        let first = Task { @MainActor in try await runs.creating("dev", account: Self.account, create) }
        #expect(await next() == .entered(1))
        let joined = Task { @MainActor in try await runs.creating("dev", account: Self.account, create) }
        #expect(await next() == .joined("dev"))
        runs.forgetAll()
        resume.value?.resume()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        await #expect(throws: CancellationError.self) { _ = try await joined.value }
    }
}
