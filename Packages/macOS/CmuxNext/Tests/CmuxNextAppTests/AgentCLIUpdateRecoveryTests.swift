import CmuxNextActions
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentUpdates
@testable import CmuxNextApp

/// The production registry path with a retained ledger shared by two UI instances.
@MainActor struct AgentCLIUpdateRecoveryTests {
    typealias JSONValue = CmuxNextSettings.JSONValue

    @MainActor final class Ledger {
        var rows: [String: AgentCLIStoredIntent] = [:]
        var events: [String] = []
        var refuse = false
        var refuseList = false
        var refuseAttach = false

        var port: AgentCLIUpdateActions.Persistence {
            .init(record: { inputs in
                self.events.append("record:\(inputs.count)")
                if self.refuse { throw DaemonError.notConnected }
                for input in inputs { self.rows[input.key] = try .init(intent: input, receipt: self.rows[input.key]?.receipt) }
            }, list: {
                if self.refuseList { throw DaemonError.notConnected }
                return Array(self.rows.values)
            }, attach: { input, receipt in
                self.events.append("attach:\(input.cli)")
                if self.refuseAttach { throw DaemonError.notConnected }
                self.rows[input.key] = try .init(intent: input, receipt: receipt)
            }, settle: { keys in
                self.events.append("settle:\(keys.count)")
                for key in keys { self.rows[key] = nil }
            })
        }
    }

    @MainActor final class Harness {
        let owner = AgentCLIUpdateActionsTests.Owner()
        let ledger: Ledger
        var resolutions = 0
        var resolution: AgentCLIJobResolution = .notFound
        var restores: [(ResourceID, ResourceID)] = []

        init(_ ledger: Ledger = Ledger()) { self.ledger = ledger }

        func make() -> (AgentCLIUpdateActions, ActionRegistry) {
            let actions = AgentCLIUpdateActions(capture: { _ in self.route() }, persistence: ledger.port,
                captureRecovered: { machine, session in
                    self.restores.append((machine, session))
                    guard machine == self.owner.machine, session == self.owner.session, self.owner.current else { throw DaemonError.notConnected }
                    return self.route()
                })
            let registry = ActionRegistry.standard(); actions.bind(into: registry)
            return (actions, registry)
        }

        func route() -> AgentCLIUpdateActions.Route {
            var route = owner.route()
            let start = route.start
            route = .init(machine: route.machine, session: route.session, isCurrent: route.isCurrent, inventory: route.inventory,
                start: { cli, key in self.ledger.events.append("start:\(cli.rawValue)"); return try await start(cli, key) }, observe: route.observe,
                resolve: { _, _ in self.resolutions += 1; return self.resolution })
            return route
        }

        func retained(_ key: String = "original-intent") throws -> AgentCLIUpdateIntent {
            try .init(key: key, rootKey: "original-root", machine: owner.machine, session: owner.session,
                cli: .codex, profiles: ["work-profile"])
        }
    }

    private func gesture(_ key: String = "original-intent", user: Bool = true) -> PageCallContext {
        .init(page: "cmux.settings", opid: key, userGesture: user, gestureEvent: user ? 1 : nil)
    }

    @Test func aLedgerFailurePreventsEveryOwnerStart() async throws {
        let h = Harness(); h.ledger.refuse = true
        let (actions, registry) = h.make()
        do { _ = try await actions.runSettings(id: "work-profile", context: gesture(), registry: registry) }
        catch {}
        #expect(h.ledger.events.first == "record:1")
        #expect(h.owner.starts.isEmpty)
    }

    @Test func anUnreadableLedgerPreventsANewIntent() async throws {
        let h = Harness(); h.ledger.refuseList = true
        let (actions, registry) = h.make()
        do { _ = try await actions.runSettings(id: "work-profile", context: gesture(), registry: registry) } catch {}
        #expect(h.owner.starts.isEmpty)
        #expect(h.ledger.rows.isEmpty)
    }

    @Test func theWholeBatchIsDurableBeforeItsFirstEffect() async throws {
        let h = Harness(); let (actions, registry) = h.make()
        _ = try await actions.runSettings(id: nil, context: gesture(), registry: registry)
        #expect(h.ledger.events == ["record:2", "start:claude", "attach:claude", "start:codex", "attach:codex"])
        #expect(Set(h.ledger.rows.keys) == Set(h.owner.starts.map { $0.1 }))
        #expect(h.ledger.rows.values.allSatisfy { $0.intent.rootKey == "original-intent" })
    }

    @Test func aNewUIRecoversTheLostReplyWithoutDispatchingAgain() async throws {
        let h = Harness(); h.owner.loseReply = true
        let (first, registry) = h.make()
        do { _ = try await first.runSettings(id: "work-profile", context: gesture(), registry: registry) } catch {}
        #expect(h.owner.starts.count == 1)
        h.resolution = .created(try h.owner.receipt(.codex))
        let (second, _) = h.make()
        try await second.recover()
        let job = try #require(second.state.arrayValue?.first)
        #expect(job["terminal"] == "term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(job["intent_key"] == "original-intent")
        #expect(h.resolutions == 1 && h.owner.starts.count == 1)
        #expect(h.restores.first?.0 == h.owner.machine && h.restores.first?.1 == h.owner.session)
    }

    @Test(arguments: ["not_found", "prepared", "pending", "indeterminate"])
    func recoveryNeverDispatchesAndBlocksAnUnrelatedFreshKey(state: String) async throws {
        let h = Harness(); let input = try h.retained()
        h.ledger.rows[input.key] = try .init(intent: input, receipt: nil)
        switch state { case "prepared": h.resolution = .prepared; case "pending": h.resolution = .pending
        case "indeterminate": h.resolution = .indeterminate; default: h.resolution = .notFound }
        let (actions, registry) = h.make()
        try await actions.recover()
        #expect(actions.state.arrayValue?.first?["state"] == "unknown")
        do { _ = try await actions.runSettings(id: "work-profile", context: gesture("fresh-key"), registry: registry) } catch {}
        #expect(h.owner.starts.isEmpty)
        #expect(h.ledger.rows.count == 1)
    }

    @Test func anExplicitResumeKeepsTheOriginalKeyAndRequiresActualUserContext() async throws {
        let h = Harness(); let input = try h.retained()
        h.ledger.rows[input.key] = try .init(intent: input, receipt: nil)
        let (actions, registry) = h.make()
        do {
            _ = try await actions.resumeRetained(key: input.key, context: gesture(user: false), registry: registry)
            Issue.record("untrusted resume")
        } catch let error as PageError { #expect(error.code == PageNativeOp.userOnlyCode) }
        #expect(h.owner.starts.isEmpty)
        _ = try await actions.resumeRetained(key: input.key, context: gesture("new-click"), registry: registry)
        #expect(h.owner.starts.count == 1)
        #expect(h.owner.starts.first?.1 == input.key)
        #expect(h.owner.starts.first?.0 == .codex)
        #expect(h.owner.reads == 0, "resume must retain the original family, not select a new plan in the UI")
    }

    @Test(arguments: ["pending", "indeterminate", "created"])
    func aResumeCannotRepeatAnAcceptedOrUnknownEffect(state: String) async throws {
        let h = Harness(); let input = try h.retained()
        h.ledger.rows[input.key] = try .init(intent: input, receipt: nil)
        h.resolution = state == "created" ? .created(try h.owner.receipt(.codex)) : state == "pending" ? .pending : .indeterminate
        let (actions, registry) = h.make()
        do { _ = try await actions.resumeRetained(key: input.key, context: gesture(), registry: registry) } catch {}
        #expect(h.owner.starts.isEmpty)
        #expect(h.resolutions > 0)
    }

    @Test func aSavedReceiptNeverBecomesPermissionToDispatchAgain() async throws {
        let h = Harness(); let input = try h.retained()
        h.ledger.rows[input.key] = try .init(intent: input, receipt: h.owner.receipt(.codex))
        let (actions, registry) = h.make()
        h.owner.outcome = "exited"
        await actions.refresh()
        #expect(actions.state.arrayValue?.first?["exit_code"] == 23)
        await actions.refresh()
        #expect(h.ledger.rows.isEmpty, "an exit settles the retained intent")
        do { _ = try await actions.resumeRetained(key: input.key, context: gesture(), registry: registry) } catch {}
        #expect(actions.state.arrayValue?.first?["state"] == "exited")
        #expect(h.resolutions == 0 && h.owner.starts.isEmpty)
    }

    @Test func withdrawnAndForeignSessionsCannotSelectAReplacement() async throws {
        let h = Harness()
        let foreign = try AgentCLIUpdateIntent(key: "original-intent", rootKey: "original-root", machine: h.owner.machine,
            session: "session_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", cli: .codex, profiles: ["work-profile"])
        h.ledger.rows[foreign.key] = try .init(intent: foreign, receipt: nil)
        let (actions, _) = h.make(); try await actions.recover()
        // Shown so a person can let it go, never resolved or started through another owner.
        let shown = try #require(actions.state.arrayValue)
        #expect(shown.count == 1 && shown.first?["state"] == "unknown" && shown.first?["terminal"] == nil)
        #expect(shown.first?["can_dismiss"] == true && shown.first?["can_resume"] == false)
        #expect(h.resolutions == 0 && h.owner.starts.isEmpty)
        h.owner.current = false
        h.ledger.rows = ["original-intent": try .init(intent: h.retained(), receipt: nil)]
        try await actions.recover()
        #expect(h.resolutions == 0 && h.owner.starts.isEmpty)
    }

    @Test func aRefusedStartSettlesInsteadOfLeavingAResumableIntent() async throws {
        let h = Harness(); h.owner.refuse = [.claude]
        let (actions, registry) = h.make()
        do { _ = try await actions.runSettings(id: nil, context: gesture(), registry: registry) } catch {}
        #expect(h.ledger.events == ["record:2", "start:claude", "settle:1", "start:codex", "attach:codex"])
        #expect(h.ledger.rows.values.map(\.intent.cli) == ["codex"])
        let (another, anotherRegistry) = h.make()
        try await another.recover()
        #expect(another.state.arrayValue?.map { $0["cli"] } == ["codex"])
        #expect(another.state.arrayValue?.contains { $0["can_resume"] == true } == false)
        h.owner.refuse = []
        _ = try await another.runSettings(id: "claude", context: gesture("later-claude"), registry: anotherRegistry)
        #expect(h.owner.starts.last?.0 == .claude && h.owner.starts.last?.1 == "later-claude")
    }

    @Test func aResumeTheOwnerRefusesSettlesSoItIsNotOfferedAgain() async throws {
        let h = Harness(); let input = try h.retained()
        h.ledger.rows[input.key] = try .init(intent: input, receipt: nil)
        h.owner.refuse = [.codex]
        let (actions, registry) = h.make()
        try await actions.recover()
        #expect(actions.state.arrayValue?.first?["can_resume"] == true)
        do {
            _ = try await actions.resumeRetained(key: input.key, context: gesture("resume-click"), registry: registry)
            Issue.record("a refused resume reported success")
        } catch {}
        #expect(h.owner.starts.count == 1 && h.ledger.rows.isEmpty)
        #expect(actions.state.arrayValue?.isEmpty == true)
        h.owner.refuse = []
        _ = try await actions.runSettings(id: "work-profile", context: gesture("fresh-key"), registry: registry)
        #expect(h.owner.starts.last?.1 == "fresh-key")
    }

    @Test func anExitWithAnUnknownOutcomeSettles() async throws {
        let h = Harness(); let input = try h.retained()
        h.ledger.rows[input.key] = try .init(intent: input, receipt: h.owner.receipt(.codex))
        h.owner.outcome = "lost"
        let (actions, registry) = h.make()
        await actions.refresh()
        let job = try #require(actions.state.arrayValue?.first)
        #expect(job["state"] == "exited" && job["exit_code"] == nil)
        #expect(h.ledger.rows.isEmpty)
        _ = try await actions.runSettings(id: "work-profile", context: gesture("after-exit"), registry: registry)
        #expect(h.owner.starts.map(\.1) == ["after-exit"])
    }

    @Test func aFailedCreationSettlesOnRecovery() async throws {
        let h = Harness(); let input = try h.retained()
        h.ledger.rows[input.key] = try .init(intent: input, receipt: nil)
        h.resolution = .failed(code: "operation.failed")
        let (actions, registry) = h.make()
        try await actions.recover()
        #expect(h.ledger.rows.isEmpty && actions.state.arrayValue?.isEmpty == true)
        _ = try await actions.runSettings(id: "work-profile", context: gesture("after-failure"), registry: registry)
        #expect(h.owner.starts.map(\.1) == ["after-failure"])
    }

    /// A kept update tab the person closed answers `terminal.closed`, then `selector.not_found`
    /// once tombstoned. Either ends the job; any other observation failure keeps it.
    @Test(arguments: ["terminal.closed", "selector.not_found", "transient"])
    func aClosedUpdateTerminalSettlesInsteadOfBlockingForever(code: String) async throws {
        let h = Harness(); let input = try h.retained()
        h.ledger.rows[input.key] = try .init(intent: input, receipt: h.owner.receipt(.codex))
        h.owner.observeError = code == "transient" ? .notConnected
            : .command(cmd: "terminal.wait_exit", message: "gone", code: code, details: CmuxNextDaemon.JSONValue.object(["scope": .string("terminal")]))
        let (actions, registry) = h.make()
        await actions.refresh()
        #expect(h.ledger.rows.isEmpty == (code != "transient"))
        #expect(actions.state.arrayValue?.first?["state"] == (code == "transient" ? "created" : "exited"))
        do { _ = try await actions.runSettings(id: "work-profile", context: gesture("after-close"), registry: registry) } catch {}
        #expect(h.owner.starts.map(\.1) == (code == "transient" ? [] : ["after-close"]))
    }

    /// Only a missing session, never a missing terminal, ends the job.
    @Test func aMissingSessionIsNotAClosedTerminal() async throws {
        let h = Harness(); let input = try h.retained()
        h.ledger.rows[input.key] = try .init(intent: input, receipt: h.owner.receipt(.codex))
        h.owner.observeError = .command(cmd: "terminal.wait_exit", message: "gone", code: "selector.not_found", details: CmuxNextDaemon.JSONValue.object(["scope": .string("session")]))
        let (actions, _) = h.make()
        await actions.refresh()
        #expect(h.ledger.rows.count == 1)
    }

    /// An unreachable session may be a live server on this machine still running the updater,
    /// so its row blocks without being selected as the owner. The row it blocks with is shown and
    /// a person may dismiss it; until then (or the ledger's seven-day read bound) nothing starts.
    @Test func aRowFromAnUnreachableSessionBlocksVisiblyUntilDismissed() async throws {
        let h = Harness()
        let foreign = try AgentCLIUpdateIntent(key: "orphan-intent", rootKey: "orphan-root", machine: h.owner.machine,
            session: "session_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", cli: .codex, profiles: ["work-profile"])
        h.ledger.rows[foreign.key] = try .init(intent: foreign, receipt: nil)
        let (actions, registry) = h.make()
        do {
            _ = try await actions.runSettings(id: "work-profile", context: gesture("blocked"), registry: registry)
            Issue.record("another session's recorded update did not block")
        } catch {}
        #expect(h.owner.starts.isEmpty && h.resolutions == 0)
        // What blocks is what the page shows.
        let blocking = try #require(actions.state.arrayValue?.first { $0["intent_key"] == "orphan-intent" })
        #expect(blocking["cli"] == "codex" && blocking["state"] == "unknown" && blocking["can_dismiss"] == true)
        let dismiss: JSONValue = ["action": "dismissUpdate", "intent": "orphan-intent"]
        do {
            _ = try await actions.runPage(dismiss, context: gesture(user: false), registry: registry)
            Issue.record("a script dismissed an intent")
        } catch let error as PageError { #expect(error.code == PageNativeOp.userOnlyCode) }
        #expect(h.ledger.rows[foreign.key] != nil)
        _ = try await actions.runPage(dismiss, context: gesture("dismiss-orphan"), registry: registry)
        #expect(h.ledger.rows[foreign.key] == nil && actions.state.arrayValue?.isEmpty == true)
        _ = try await actions.runSettings(id: "work-profile", context: gesture("current-session"), registry: registry)
        #expect(h.owner.starts.map(\.1) == ["current-session"])
        #expect(h.ledger.rows.keys.contains("current-session"))
    }

    /// A row the ledger stops returning (past its seven-day read bound) no longer blocks.
    @Test func aRowPastTheAgeBoundNoLongerBlocks() async throws {
        let h = Harness()
        let foreign = try AgentCLIUpdateIntent(key: "orphan-intent", rootKey: "orphan-root", machine: h.owner.machine,
            session: "session_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", cli: .codex, profiles: ["work-profile"])
        h.ledger.rows[foreign.key] = try .init(intent: foreign, receipt: nil)
        let (actions, registry) = h.make()
        do { _ = try await actions.runSettings(id: "work-profile", context: gesture("blocked"), registry: registry) } catch {}
        h.ledger.rows[foreign.key] = nil
        _ = try await actions.runSettings(id: "work-profile", context: gesture("current-session"), registry: registry)
        #expect(h.owner.starts.map(\.1) == ["current-session"])
    }

    /// A start whose receipt the ledger fails to keep still ran: the batch reports it and goes on.
    @Test func aFailedAttachIsReportedAndTheBatchContinues() async throws {
        let h = Harness(); h.ledger.refuseAttach = true
        let (actions, registry) = h.make()
        do {
            _ = try await actions.runSettings(id: nil, context: gesture("attach-fails"), registry: registry)
            Issue.record("a failed attach reported success")
        } catch let error as PageError { #expect(error.message.contains("claude") && error.message.contains("codex")) }
        #expect(h.owner.starts.map { $0.0.rawValue } == ["claude", "codex"])
        let jobs = try #require(actions.state.arrayValue)
        #expect(jobs.map { $0["cli"] } == ["claude", "codex"] && jobs.allSatisfy { $0["state"] == "created" })
    }

    /// Nothing starts before the ledger records; a failed record leaves no job that blocks.
    @Test func aFailedRecordLeavesNoBlockingJob() async throws {
        let h = Harness(); h.ledger.refuse = true
        let (actions, registry) = h.make()
        do { _ = try await actions.runSettings(id: "work-profile", context: gesture("unrecorded"), registry: registry) } catch {}
        #expect(actions.state.arrayValue?.isEmpty == true)
        h.ledger.refuse = false
        _ = try await actions.runSettings(id: "work-profile", context: gesture("recorded"), registry: registry)
        #expect(h.owner.starts.map(\.1) == ["recorded"])
    }

    /// Refresh replays a lost start reply by its key (#21447); its ledger row follows the
    /// owner's answer: a receipt attaches, a refusal or another owner's receipt settles it,
    /// and busy (the key's original request may still run) keeps it.
    @Test(arguments: ["receipt", "refused", "mismatch", "busy"])
    func aReplayedStartKeepsItsLedgerRowConsistent(answer: String) async throws {
        let h = Harness(); h.owner.loseReply = true
        h.resolution = .indeterminate // the owner cannot say; the replay is the only path
        let (actions, registry) = h.make()
        do { _ = try await actions.runSettings(id: "work-profile", context: gesture("lost-start"), registry: registry) } catch {}
        #expect(h.ledger.rows["lost-start"]?.receipt == nil)
        h.owner.loseReply = false
        switch answer {
        case "refused": h.owner.refuse = [.codex]
        case "mismatch": h.owner.mismatch = true
        case "busy": h.owner.busy = [.codex]
        default: break
        }
        await actions.refresh()
        #expect(h.owner.starts.map(\.1) == ["lost-start", "lost-start"])
        let row = h.ledger.rows["lost-start"]
        switch answer {
        case "receipt":
            #expect(row?.receipt?.path.terminalID.rawValue == "term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            #expect(actions.state.arrayValue?.first?["terminal"] == "term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        case "busy":
            #expect(row != nil && row?.receipt == nil)
            #expect(actions.state.arrayValue?.count == 1)
        default:
            #expect(row == nil && actions.state.arrayValue?.isEmpty == true)
        }
    }

    /// A creation still pending well after a first recovery saw it may be dismissed.
    @Test func aLongPendingCreationBecomesDismissable() async throws {
        let h = Harness(); let input = try h.retained()
        h.ledger.rows[input.key] = try .init(intent: input, receipt: nil)
        h.resolution = .pending
        let (actions, registry) = h.make()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        actions.now = { clock }
        try await actions.recover()
        #expect(actions.state.arrayValue?.first?["can_dismiss"] == false)
        clock += AgentCLIUpdateActions.pendingDismissAfter - 1
        try await actions.recover()
        #expect(actions.state.arrayValue?.first?["can_dismiss"] == false)
        clock += 1
        try await actions.recover()
        #expect(actions.state.arrayValue?.first?["can_dismiss"] == true)
        _ = try await actions.runPage(["action": "dismissUpdate", "intent": .string(input.key)], context: gesture("dismiss"), registry: registry)
        #expect(h.ledger.rows.isEmpty && h.owner.starts.isEmpty)
    }

    /// The owner answers busy (its inventory reservation or execution lock) before it looks up
    /// the key, and a first start always sends a fresh key: nothing was created for it. The row
    /// settles, so a retry click is not blocked and no later refresh starts it unasked.
    @Test func aBusyFirstStartSettlesAndLeavesTheCLIUnblocked() async throws {
        let h = Harness(); h.owner.busy = [.claude]
        let (actions, registry) = h.make()
        do { _ = try await actions.runSettings(id: nil, context: gesture(), registry: registry) } catch {}
        #expect(h.ledger.events == ["record:2", "start:claude", "settle:1", "start:codex", "attach:codex"])
        #expect(h.ledger.rows.values.map(\.intent.cli) == ["codex"])
        #expect(actions.state.arrayValue?.map { $0["cli"] } == ["codex"])
        await actions.refresh()
        #expect(h.owner.starts.count == 2, "no refresh replays a start the owner answered busy")
        h.owner.busy = []
        _ = try await actions.runSettings(id: "claude", context: gesture("retry-claude"), registry: registry)
        #expect(h.owner.starts.last?.0 == .claude && h.owner.starts.last?.1 == "retry-claude")
    }

    /// A lost reply whose key the owner has nothing for (not_found or prepared) is offered as
    /// Resume, which needs a click; a refresh never sends it again unasked.
    @Test(arguments: ["not_found", "prepared"])
    func aLostReplyTheOwnerHasNothingForOffersResumeInsteadOfReplaying(state: String) async throws {
        let h = Harness(); h.owner.loseReply = true
        h.resolution = state == "prepared" ? .prepared : .notFound
        let (actions, registry) = h.make()
        do { _ = try await actions.runSettings(id: "work-profile", context: gesture("lost-nothing"), registry: registry) } catch {}
        h.owner.loseReply = false
        await actions.refresh()
        await actions.refresh()
        #expect(h.owner.starts.map(\.1) == ["lost-nothing"])
        let job = try #require(actions.state.arrayValue?.first)
        #expect(job["intent_key"] == "lost-nothing" && job["can_resume"] == true && job["terminal"] == nil)
        _ = try await actions.resumeRetained(key: "lost-nothing", context: gesture("resume-click"), registry: registry)
        #expect(h.owner.starts.map(\.1) == ["lost-nothing", "lost-nothing"])
    }

    /// A replay in flight holds its intent: a dismiss then is refused instead of deleting the row
    /// the replayed receipt attaches to, so no updater runs untracked.
    @Test func aDismissDuringAReplayIsRefusedAndTheReceiptAttaches() async throws {
        let h = Harness(); h.owner.loseReply = true
        h.resolution = .indeterminate
        let (actions, registry) = h.make()
        do { _ = try await actions.runSettings(id: "work-profile", context: gesture("lost-held"), registry: registry) } catch {}
        h.owner.loseReply = false
        h.owner.hold = .codex
        let refresh = Task { await actions.refresh() }
        for _ in 0..<200 where h.owner.held == nil { await Task.yield() }
        let held = try #require(h.owner.held)
        do {
            _ = try await actions.runPage(["action": "dismissUpdate", "intent": "lost-held"], context: gesture("dismiss-click"), registry: registry)
            Issue.record("a dismiss settled a key whose replay is in flight")
        } catch {}
        #expect(h.ledger.rows["lost-held"] != nil)
        held.resume()
        await refresh.value
        #expect(h.ledger.rows["lost-held"]?.receipt?.path.terminalID.rawValue == "term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(actions.state.arrayValue?.first?["terminal"] == "term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    }

    /// A batch that stops early names the families it never sent.
    @Test func aBatchThatStopsEarlyNamesTheFamiliesItDropped() async throws {
        let h = Harness(); h.owner.hold = .claude
        let (actions, registry) = h.make()
        let batch = Task { try await actions.runSettings(id: nil, context: gesture("stops-early"), registry: registry) }
        for _ in 0..<200 where h.owner.held == nil { await Task.yield() }
        let held = try #require(h.owner.held)
        h.owner.epoch += 1
        h.owner.loseReply = true
        held.resume()
        do {
            _ = try await batch.value
            Issue.record("a batch that lost its route reported success")
        } catch let error as PageError { #expect(error.message.contains("claude") && error.message.contains("codex")) }
        #expect(h.owner.starts.map(\.0) == [.claude])
    }

    @Test(arguments: ["indeterminate", "not_found", "pending"])
    func onlyAnIntentNothingRunsForCanBeDismissed(state: String) async throws {
        let h = Harness(); let input = try h.retained()
        h.ledger.rows[input.key] = try .init(intent: input, receipt: nil)
        h.resolution = state == "pending" ? .pending : state == "indeterminate" ? .indeterminate : .notFound
        let (actions, registry) = h.make()
        try await actions.recover()
        #expect(actions.state.arrayValue?.first?["can_dismiss"] == .bool(state != "pending"))
        let dismiss: JSONValue = ["action": "dismissUpdate", "intent": .string(input.key)]
        do {
            _ = try await actions.runPage(dismiss, context: gesture(user: false), registry: registry)
            Issue.record("a script dismissed an intent")
        } catch let error as PageError { #expect(error.code == PageNativeOp.userOnlyCode) }
        do { _ = try await actions.runPage(dismiss, context: gesture("dismiss-click"), registry: registry) } catch {}
        #expect(h.ledger.rows.isEmpty == (state != "pending"))
        #expect(actions.state.arrayValue?.isEmpty == (state != "pending"))
        #expect(h.owner.starts.isEmpty)
    }
}
