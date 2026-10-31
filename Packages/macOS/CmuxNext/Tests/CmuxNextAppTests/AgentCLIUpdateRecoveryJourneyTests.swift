import AppKit
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextAgentUpdates
@testable import CmuxNextApp

/// The production AppServices composition over a private proved native owner.
/// No acpmux, registry fetch, package manager or terminal execution is needed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)),
                  .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentCLIUpdateRecoveryJourneyTests {
    @Test func anotherUIReadsTheHomeLedgerWithoutExecutingOrSelectingAForeignOwner() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/cn-uprecover-\(UUID().uuidString.prefix(8).lowercased())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = FrontendInstallKey.generate()
        var configuration = DaemonLauncher.Configuration(binary: try #require(SameTreeDaemonBinary.url),
            session: root.lastPathComponent, stateDirectory: root.appendingPathComponent("state"), installKey: key)
        configuration.runtimeBase = root.appendingPathComponent("run")
        let environment = ["HOME": root.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh",
                           "ACPMUX_CATALOG_FETCH": "0", "ACPMUX_REGISTRY_FETCH": "0", "ACPMUX_HEALTH_FETCH": "0"]
        let launcher = DaemonLauncher(configuration: configuration, environment: { environment })
        let owner = try await launcher.ensure()
        let connectionConfiguration = DaemonConnection.Configuration(terminalEnvironment: nil, clientHello: .init(installKey: key))
        let control = DaemonConnection(endpoint: owner.endpoint, configuration: connectionConfiguration)
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_NO_ACTIVATE": "1"]))
        do {
            let identity = try await control.start()
            let machine = try #require(identity.machineResourceID)
            let session = try #require(identity.sessionResourceID)
            let ledger = try await control.agentCLIIntentLedger(expectedMachineID: machine, expectedSessionID: session)
            let original = try AgentCLIUpdateIntent(key: "saved-original", rootKey: "saved-batch", machine: machine,
                session: session, cli: .codex, profiles: ["work-profile"])
            let foreign = try AgentCLIUpdateIntent(key: "foreign-owner", rootKey: "foreign-batch",
                machine: "machine_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", session: "session_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                cli: .claude, profiles: ["foreign-profile"])
            _ = try await ledger.record([original, foreign])
            services.daemon.start { DaemonConnection(endpoint: owner.endpoint, configuration: connectionConfiguration) }
            await ObservationDeadline(owner: "AgentCLIUpdateRecoveryJourneyTests.attach").until({
                guard case .connected = services.daemon.store.connectionState else { return false }
                return services.daemon.identity?.sessionResourceID == session && services.daemon.connection != nil
            }, limit: .seconds(20))
            #expect(services.daemon.identity?.sessionResourceID == session)

            let first = AgentCLIUpdateActions(services: services)
            try await first.recover()
            let another = AgentCLIUpdateActions(services: services)
            try await another.recover()
            let jobs = try #require(another.state.arrayValue)
            #expect(jobs.count == 2)
            let saved = try #require(jobs.first { $0["intent_key"] == "saved-original" })
            #expect(saved["machine"]?.stringValue == machine.rawValue)
            #expect(saved["session"]?.stringValue == session.rawValue)
            #expect(saved["can_resume"] == true)
            #expect(saved["terminal"] == nil)
            // The foreign owner's row is never selected as an owner; it is shown so a person may let it go.
            let unreachable = try #require(jobs.first { $0["intent_key"] == "foreign-owner" })
            #expect(unreachable["state"] == "unknown" && unreachable["can_dismiss"] == true && unreachable["can_resume"] == false)
            let retained = try await ledger.list()
            #expect(retained.count == 2)
            let jobsCarrier = try await control.agentCLIJobs(expectedMachineID: machine, expectedSessionID: session)
            let resolved = try await jobsCarrier.resolveUpdate(cli: .codex, idempotencyKey: original.key)
            #expect(resolved == .notFound)

            services.daemon.policyBlock.set(true)
            do { try await another.recover() } catch {}
            #expect(another.state.arrayValue?.isEmpty == true)
        } catch {
            services.daemon.shutdownConnection()
            _ = await control.endSessionsAndStop()
            throw error
        }
        services.daemon.shutdownConnection()
        let stopped = await control.endSessionsAndStop()
        #expect(stopped.failures.isEmpty)
    }
}
