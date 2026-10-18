import CmuxNextActions
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// The production registry path with a retained ledger shared by two UI instances.
@MainActor struct AgentCLIUpdateRecoveryTests {
    typealias JSONValue = CmuxNextSettings.JSONValue

    @MainActor final class Ledger {
        var rows: [String: AgentCLIStoredIntent] = [:]
        var events: [String] = []
        var refuse = false

        var port: AgentCLIUpdateActions.Persistence {
            .init(record: { inputs in
                self.events.append("record:\(inputs.count)")
                if self.refuse { throw DaemonError.notConnected }
                for input in inputs { self.rows[input.key] = try .init(intent: input, receipt: self.rows[input.key]?.receipt) }
            }, list: { Array(self.rows.values) }, attach: { input, receipt in
                self.events.append("attach:\(input.cli)")
                self.rows[input.key] = try .init(intent: input, receipt: receipt)
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

    @Test func withdrawnAndForeignSessionsCannotSelectAReplacement() async throws {
        let h = Harness()
        let foreign = try AgentCLIUpdateIntent(key: "original-intent", rootKey: "original-root", machine: h.owner.machine,
            session: "session_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", cli: .codex, profiles: ["work-profile"])
        h.ledger.rows[foreign.key] = try .init(intent: foreign, receipt: nil)
        let (actions, _) = h.make(); try await actions.recover()
        #expect(actions.state.arrayValue?.isEmpty == true && h.resolutions == 0 && h.owner.starts.isEmpty)
        h.owner.current = false
        h.ledger.rows = ["original-intent": try .init(intent: h.retained(), receipt: nil)]
        try await actions.recover()
        #expect(h.resolutions == 0 && h.owner.starts.isEmpty)
    }
}
