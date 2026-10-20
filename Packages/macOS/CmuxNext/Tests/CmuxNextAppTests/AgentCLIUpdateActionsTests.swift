import CmuxNextActions
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentUpdates
@testable import CmuxNextApp

/// Settings and palette use the production registry binding; the owner boundary
/// records requests and returns terminal receipts without running a package manager.
@MainActor struct AgentCLIUpdateActionsTests {
    typealias JSONValue = CmuxNextSettings.JSONValue
    @MainActor final class Owner {
        var starts: [(AgentCLIFamily, String)] = []
        var captures = 0
        var reads = 0
        var observations = 0
        var current = true
        var loseReply = false
        var outcome = "pending"
        var refuse: Set<AgentCLIFamily> = []
        var refuseCode = "agent_cli_job.refused"
        var observeError: DaemonError?
        var claudeChannel = "native"
        /// A reconnect advances the epoch; routes captured before it retire.
        var epoch = 0
        /// The owner answers with a receipt for another machine.
        var mismatch = false
        let machine: ResourceID = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        var session: ResourceID = "session_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

        func route() -> AgentCLIUpdateActions.Route {
            captures += 1
            let epoch = self.epoch
            return .init(machine: machine, session: session, isCurrent: { self.current && self.epoch == epoch }, inventory: {
                self.reads += 1
                return try JSONDecoder().decode(AcpmuxHarnessInventory.self, from: Data(#"{"view":"inventory","cached":true,"harnesses":[{"id":"work-profile","family":"codex","channel":"npm","version":"1","latest":"2","outdated":true,"auth":"unknown","checkedAt":1},{"id":"another-profile","family":"codex","channel":"npm","version":"1","latest":"2","outdated":true,"auth":"unknown","checkedAt":1},{"id":"claude","family":"claude","channel":"\#(self.claudeChannel)","version":"1","latest":"2","outdated":true,"auth":"unknown","checkedAt":1},{"id":"codex","channel":"npm","version":"1","latest":"2","outdated":true,"auth":"unknown","checkedAt":1}]}"#.utf8))
            }, start: { cli, key in
                self.starts.append((cli, key))
                if self.refuse.contains(cli) {
                    throw DaemonError.command(cmd: "agent-cli-update-job", message: "The owner could not start the update job",
                                              code: self.refuseCode)
                }
                if self.loseReply { throw DaemonError.notConnected }
                return try self.receipt(cli)
            }, observe: { receipt in
                self.observations += 1
                if let error = self.observeError { throw error }
                let result = switch self.outcome {
                case "pending": #"{"state":"pending","lifecycle":"running","revision":"7"}"#
                case "unknown", "lost": #"{"state":"exited","lifecycle":"exited","revision":"8","exited_at":"1","outcome":{"kind":"\#(self.outcome)"}}"#
                default: #"{"state":"exited","lifecycle":"exited","revision":"8","exited_at":"1","outcome":{"kind":"exit","code":23}}"#
                }
                var value = try JSONValue.parse(Data(result.utf8)).objectValue ?? [:]
                value["terminal_id"] = .string(receipt.path.terminalID.rawValue)
                return try JSONDecoder().decode(AgentCLIJobStatus.self, from: Data(JSONValue.object(value).compactText.utf8))
            })
        }

        func receipt(_ cli: AgentCLIFamily) throws -> AgentCLIJobReceipt {
            let suffix = String(repeating: cli == .codex ? "a" : "b", count: 32)
            let owner = mismatch ? "machine_cccccccccccccccccccccccccccccccc" : machine.rawValue
            let value: JSONValue = ["machine": .string(owner), "session": .string(session.rawValue),
                "cli": .string(cli.rawValue), "revision": "1", "replayed": false,
                "path": ["kind": "terminal", "workspace_id": .string("ws_" + suffix), "screen_id": .string("screen_" + suffix),
                    "pane_id": .string("pane_" + suffix), "tab_id": .string("tab_" + suffix), "terminal_id": .string("term_" + suffix)]]
            return try JSONDecoder().decode(AgentCLIJobReceipt.self, from: Data(value.compactText.utf8))
        }
    }

    @MainActor final class Notices {
        var shown: [(String, Bool)] = []
    }

    private func make() -> (Owner, AgentCLIUpdateActions, ActionRegistry) {
        let owner = Owner()
        let ledger = AgentCLIUpdateRecoveryTests.Ledger()
        let updates = AgentCLIUpdateActions(capture: { _ in owner.route() }, persistence: ledger.port)
        let registry = ActionRegistry.standard()
        updates.bind(into: registry)
        return (owner, updates, registry)
    }

    private func page(_ key: String = "original-operation", user: Bool = true) -> PageCallContext {
        .init(page: "cmux.settings", opid: key, userGesture: user, gestureEvent: user ? 1 : nil)
    }

    @Test func settingsUsesTheOwnersFamilyAndOriginalKeyInsteadOfTheProfileName() async throws {
        let (owner, updates, registry) = make()
        _ = try await updates.runSettings(id: "work-profile", context: page(), registry: registry)
        #expect(owner.starts.count == 1)
        #expect(owner.starts.first?.0 == .codex && owner.starts.first?.1 == "original-operation")
        let job = try #require(updates.state.arrayValue?.first)
        #expect(job["machine"] == .string(owner.machine.rawValue) && job["session"] == .string(owner.session.rawValue))
        #expect(job["terminal"] == "term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(job["state"] == "created")
    }

    @Test func settingsAndPaletteRunOneJobPerObservedFamilyThroughTheSameHandler() async throws {
        let (owner, updates, registry) = make()
        _ = try await updates.runSettings(id: nil, context: page("settings-batch"), registry: registry)
        #expect(owner.starts.map { $0.0.rawValue } == ["claude", "codex"])
        #expect(Set(owner.starts.map { $0.1 }).count == 2)
        #expect(owner.starts.allSatisfy { $0.1 != "settings-batch" })
        let first = owner.starts.map { $0.1 }
        _ = try await updates.runSettings(id: nil, context: page("settings-batch"), registry: registry)
        #expect(owner.starts.count == 2)
        #expect(owner.starts.map { $0.1 } == first)
        #expect(owner.captures == 1)
        let (paletteOwner, palette, paletteRegistry) = make()
        let work = paletteRegistry.capturingWork { paletteRegistry.perform("agent.harness.updateAll") }
        for task in work { #expect(await task.value == nil) }
        #expect(paletteOwner.starts.map { $0.0.rawValue } == ["claude", "codex"])
        #expect(palette.state.arrayValue?.count == 2)
    }

    @Test func profileNamesCannotSubstituteForMissingFamilyEvidence() async throws {
        let (owner, updates, registry) = make()
        do {
            _ = try await updates.runSettings(id: "codex", context: page(), registry: registry)
            Issue.record("profile name invented family evidence")
        } catch {}
        #expect(owner.starts.isEmpty)
    }

    @Test func scriptsAndAppGesturesCannotBorrowFrontendExecution() async throws {
        let (owner, updates, registry) = make()
        do {
            _ = try await updates.runSettings(id: nil, context: page(user: false), registry: registry)
            Issue.record("page without a gesture updated")
        } catch let error as PageError { #expect(error.code == PageNativeOp.userOnlyCode) }
        for origin in [ActionOrigin.script, .cli, .user] {
            var invocation = ActionInvocation(origin: origin)
            if origin == .user { invocation.callerApp = "example.app" }
            let work = registry.capturingWork { registry.perform("agent.harness.updateAll", invocation: invocation) }
            for task in work { _ = await task.value }
        }
        let bridge = RegistryControlBridge(registry: registry)
        let result = bridge.performAction(.init(actionID: "agent.harness.updateAll", origin: "user"))
        if case .refused = result {} else { Issue.record("a wire user claim reached a person-only action") }
        #expect(owner.captures == 0 && owner.starts.isEmpty)
    }

    @Test func retiredRoutesNeverStartAndAReplyLossNeverChangesTheIntent() async throws {
        let (owner, updates, registry) = make()
        owner.loseReply = true
        for _ in 0..<2 {
            do { _ = try await updates.runSettings(id: "work-profile", context: page(), registry: registry) } catch {}
        }
        #expect(owner.starts.count == 1)
        #expect(updates.state.arrayValue?.first?["state"] == "unknown")
        owner.current = false
        await updates.refresh()
        #expect(owner.starts.count == 1 && owner.observations == 0)
        let (retired, actions, actionsRegistry) = make()
        retired.current = false
        do { _ = try await actions.runSettings(id: nil, context: page(), registry: actionsRegistry) } catch {}
        #expect(retired.reads == 0 && retired.starts.isEmpty)
    }

    @Test func onlyTerminalObservationCanCompleteAnUpdate() async throws {
        let (owner, updates, registry) = make()
        _ = try await updates.runSettings(id: "work-profile", context: page(), registry: registry)
        await updates.refresh()
        #expect(updates.state.arrayValue?.first?["state"] == "pending")
        owner.outcome = "exited"
        await updates.refresh()
        let job = try #require(updates.state.arrayValue?.first)
        #expect(job["state"] == "exited" && job["exit_code"] == 23)
        #expect(owner.starts.count == 1 && owner.observations == 2)
    }

    @Test func familiesTheOwnerRefusesAreNeverOfferedOrSubmitted() async throws {
        for channel in ["brewCask", "brew", "standalone", "bun"] {
            let (owner, updates, registry) = make()
            owner.claudeChannel = channel
            _ = try await updates.runSettings(id: nil, context: page("batch-\(channel)"), registry: registry)
            #expect(owner.starts.map { $0.0.rawValue } == ["codex"], "\(channel)")
            do {
                _ = try await updates.runSettings(id: "claude", context: page("one-\(channel)"), registry: registry)
                Issue.record("a \(channel) installation reached the owner")
            } catch {}
            #expect(owner.starts.count == 1)
            #expect(updates.state.arrayValue?.map { $0["cli"] } == ["codex"])
        }
    }

    @Test func aRefusedStartLeavesNoBlockingJobAndTheBatchContinues() async throws {
        let (owner, updates, registry) = make()
        owner.refuse = [.claude]
        do {
            _ = try await updates.runSettings(id: nil, context: page("refused-batch"), registry: registry)
            Issue.record("a refused family reported success")
        } catch let error as PageError { #expect(error.message.contains("claude")) }
        #expect(owner.starts.map { $0.0.rawValue } == ["claude", "codex"])
        let jobs = try #require(updates.state.arrayValue)
        #expect(jobs.map { $0["cli"] } == ["codex"] && jobs.first?["state"] == "created")
        owner.refuse = []
        _ = try await updates.runSettings(id: "claude", context: page("after-refusal"), registry: registry)
        #expect(owner.starts.last?.0 == .claude && owner.starts.last?.1 == "after-refusal")
        #expect(updates.state.arrayValue?.contains { $0["cli"] == "claude" && $0["state"] == "created" } == true)
    }

    @Test func aReconnectToTheSameOwnerKeepsTheJobVisibleAndObservedUntilItEnds() async throws {
        let (owner, updates, registry) = make()
        _ = try await updates.runSettings(id: "work-profile", context: page("before-reconnect"), registry: registry)
        owner.epoch += 1
        #expect(updates.state.arrayValue?.first?["state"] == "created")
        await updates.refresh()
        #expect(owner.observations == 1)
        #expect(updates.state.arrayValue?.first?["state"] == "pending")
        do {
            _ = try await updates.runSettings(id: "work-profile", context: page("while-pending"), registry: registry)
            Issue.record("a second update started while the first still runs")
        } catch {}
        #expect(owner.starts.count == 1)
        owner.outcome = "exited"
        await updates.refresh()
        _ = try await updates.runSettings(id: "work-profile", context: page("after-reconnect"), registry: registry)
        #expect(owner.starts.count == 2 && owner.starts.last?.1 == "after-reconnect")
    }

    /// A new daemon session cannot reach the old job, so its in-memory job neither shows nor
    /// blocks. Its ledger row still blocks the CLI on that machine (the old session may be a live
    /// second server still running the updater), shown and dismissable instead of invisible.
    @Test func aNewDaemonSessionRetiresTheOldJobAndShowsItsBlockingRowUntilDismissed() async throws {
        let (owner, updates, registry) = make()
        _ = try await updates.runSettings(id: "work-profile", context: page("first-session"), registry: registry)
        owner.session = "session_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        owner.epoch += 1
        do {
            _ = try await updates.runSettings(id: "work-profile", context: page("second-session"), registry: registry)
            Issue.record("another session's recorded update did not block")
        } catch {}
        #expect(owner.starts.count == 1)
        #expect(updates.state.arrayValue?.contains { $0["terminal"] == "term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" } == false)
        // The row that blocks is shown, and a person may dismiss it.
        let blocking = try #require(updates.state.arrayValue?.first { $0["intent_key"] == "first-session" })
        #expect(blocking["session"] == "session_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" && blocking["can_dismiss"] == true)
        _ = try await updates.runPage(["action": "dismissUpdate", "intent": "first-session"], context: page("dismiss"), registry: registry)
        _ = try await updates.runSettings(id: "work-profile", context: page("after-dismiss"), registry: registry)
        #expect(owner.starts.count == 2 && owner.starts.last?.1 == "after-dismiss")
    }

    @Test func anExitWithAnUnknownOutcomeSettlesTheJobWithoutBlockingTheCLI() async throws {
        let (owner, updates, registry) = make()
        owner.outcome = "unknown"
        _ = try await updates.runSettings(id: "work-profile", context: page("unknown-outcome"), registry: registry)
        await updates.refresh()
        let job = try #require(updates.state.arrayValue?.first)
        #expect(job["state"] == "exited" && job["outcome"] == "unknown")
        _ = try await updates.runSettings(id: "work-profile", context: page("after-unknown"), registry: registry)
        #expect(owner.starts.count == 2 && owner.starts.last?.1 == "after-unknown")
    }

    @Test func aReceiptForAnotherOwnerLeavesNoBlockingJob() async throws {
        let (owner, updates, registry) = make()
        owner.mismatch = true
        do {
            _ = try await updates.runSettings(id: "work-profile", context: page("mismatched"), registry: registry)
            Issue.record("a receipt for another machine was accepted")
        } catch {}
        #expect(updates.state.arrayValue?.isEmpty == true)
        owner.mismatch = false
        _ = try await updates.runSettings(id: "work-profile", context: page("after-mismatch"), registry: registry)
        #expect(owner.starts.count == 2 && owner.starts.last?.1 == "after-mismatch")
    }

    @Test func thePaletteShowsAFailureNoCallerWaitsFor() async throws {
        let (owner, _, registry) = make()
        owner.refuse = [.claude, .codex]
        let notices = Notices()
        registry.refusalObserver = { notices.shown.append(($0, $1)) }
        _ = registry.perform("agent.harness.updateAll")
        for _ in 0..<200 where notices.shown.isEmpty { await Task.yield() }
        #expect(owner.starts.count == 2)
        let refusal = try #require(notices.shown.first)
        #expect(refusal.0.contains("claude") && refusal.0.contains("codex") && !refusal.1)
    }
}
