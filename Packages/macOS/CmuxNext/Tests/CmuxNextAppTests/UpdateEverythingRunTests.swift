import AppKit
import CmuxNextActions
import CmuxNextDaemonService
import CmuxNextUpdateEverything
import CmuxNextUpdater
import Foundation
import Testing

/// Update Everything (cx-1mbnu) as a person runs it, through its runner and the update paths the
/// App gives it: every machine updates its agent CLIs with its threads continued, the app's own
/// update comes last behind a relaunch note, and the relaunched app (a new build) updates the
/// machines' daemons to its own build and finishes the run. A machine whose chats could not
/// restart says so in the result instead of "Everything is updated".
@MainActor
struct UpdateEverythingRunTests {
    @Test func aRunUpdatesEveryMachineThenTheAppLastAndTheRelaunchFinishesIt() async throws {
        let (journal, cleanup) = Self.journal()
        defer { cleanup() }
        let steps = RecordingSteps()
        steps.agentsAfterDaemon["ssh:devbox"] = [UpdateEverythingChange(id: "codex", name: "Codex", from: "0.1", to: "0.2")]
        let plan = UpdateEverythingPlan(machines: [Self.thisMac, Self.devbox])

        let runner = UpdateEverythingRunner(journal: journal, appVersion: "100")
        #expect(runner.claim())
        let outcomes = await runner.run(plan, continueThreads: true, steps: steps)
        runner.release()

        #expect(outcomes.map(\.failure) == [nil, nil])
        #expect(UpdateEverythingOutcome.summary(outcomes) == nil, "every machine updated")
        // devbox's daemon waits for the relaunched app's newer build: updating it to this build
        // first would replace it twice.
        #expect(!steps.log.contains { $0.contains("ssh:devbox") }, "devbox waits for the relaunch")
        #expect(steps.log.contains("agents local claude continue"))
        // The app's update relaunches, so it is the run's last step.
        #expect(steps.log.last == "install app")

        // The relaunched app (a new build) waits for devbox, then updates its daemon once.
        steps.log.removeAll()
        let again = await UpdateEverythingRunner(journal: journal, appVersion: "101").finishAfterRelaunch(plan: { ids in
            #expect(ids == ["ssh:devbox"])
            var mac = Self.thisMac
            mac.harnesses = []
            return UpdateEverythingPlan(machines: [mac, Self.devbox])
        }, steps: steps)
        #expect(again?.map(\.failure) == [nil])
        #expect(steps.log == ["daemon ssh:devbox", "agents ssh:devbox codex continue"])
        #expect(!steps.log.contains("install app"), "the app installs once")
        // The note is gone: a third launch finishes nothing.
        #expect(await UpdateEverythingRunner(journal: journal, appVersion: "101").finishAfterRelaunch(plan: { _ in plan }, steps: steps) == nil)
    }

    @Test func aLaunchOfTheSameAppVersionFinishesNothing() async throws {
        let (journal, cleanup) = Self.journal()
        defer { cleanup() }
        let steps = RecordingSteps()
        let plan = UpdateEverythingPlan(machines: [Self.thisMac, Self.devbox])
        _ = await UpdateEverythingRunner(journal: journal, appVersion: "100").run(plan, continueThreads: true, steps: steps)
        #expect(steps.log.last == "install app")

        // The app update failed or was postponed after it started: the app launches again on the
        // same build, so no daemon restarts, agent CLI updates or thread restarts run unasked.
        steps.log.removeAll()
        var asked = false
        let again = await UpdateEverythingRunner(journal: journal, appVersion: "100").finishAfterRelaunch(plan: { _ in
            asked = true
            return plan
        }, steps: steps)
        #expect(again == nil)
        #expect(!asked)
        #expect(steps.log.isEmpty)
        // The note is discarded, so a later launch of a new build does not finish it either.
        #expect(await UpdateEverythingRunner(journal: journal, appVersion: "101").finishAfterRelaunch(plan: { _ in plan }, steps: steps) == nil)
    }

    @Test func anAppUpdateThatCannotStartClearsTheNoteAndUpdatesTheDaemonsNow() async throws {
        let (journal, cleanup) = Self.journal()
        defer { cleanup() }
        let steps = RecordingSteps()
        steps.installFailure = "no update is staged"
        let plan = UpdateEverythingPlan(machines: [Self.thisMac, Self.devbox])

        let outcomes = await UpdateEverythingRunner(journal: journal, appVersion: "100").run(plan, continueThreads: true, steps: steps)

        #expect(outcomes.map(\.machineID) == ["local", "ssh:devbox"])
        #expect(outcomes.map(\.failure) == ["no update is staged", nil])
        // No relaunch comes, so devbox's daemon updates to this build now.
        #expect(steps.log.contains("daemon ssh:devbox"))
        #expect(await UpdateEverythingRunner(journal: journal, appVersion: "101").finishAfterRelaunch(plan: { _ in plan }, steps: steps) == nil,
                "the note is cleared")
    }

    @Test func aFailedDaemonUpdateStopsThatMachinesAgentUpdate() async throws {
        let (journal, cleanup) = Self.journal()
        defer { cleanup() }
        let steps = RecordingSteps()
        steps.daemonFailures["ssh:devbox"] = "the machine is not connected"
        var devbox = Self.devbox
        devbox.harnesses = [UpdateEverythingChange(id: "codex", name: "Codex", from: "0.1", to: "0.2")]
        var mac = Self.thisMac
        mac.app = nil

        let outcomes = await UpdateEverythingRunner(journal: journal, appVersion: "100")
            .run(UpdateEverythingPlan(machines: [mac, devbox]), continueThreads: true, steps: steps)

        #expect(outcomes.map(\.failure) == [nil, "the machine is not connected"])
        #expect(!steps.log.contains { $0.hasPrefix("agents ssh:devbox") })
        #expect(steps.log.contains("agents local claude continue"), "other machines are not affected")
    }

    @Test func aDaemonThatDoesNotNameItsBuildIsNotCalledOutdated() {
        let bundled = "0123456789abcdef0123456789abcdef01234567"
        #expect(UpdateEverythingDaemon.daemonChange(kind: .ssh, running: nil, bundled: bundled) == nil)
        #expect(UpdateEverythingDaemon.daemonChange(kind: .cloud, running: "", bundled: bundled) == nil)
        #expect(UpdateEverythingDaemon.daemonChange(kind: .ssh, running: "0123456", bundled: bundled) == nil)
        #expect(UpdateEverythingDaemon.daemonChange(kind: .local, running: "fedcba9", bundled: bundled) == nil)
        #expect(UpdateEverythingDaemon.daemonChange(kind: .ssh, running: "fedcba9876", bundled: bundled)
            == UpdateEverythingChange(name: UpdateEverythingMachine.daemonName, from: "fedcba9", to: "0123456"))
    }

    @Test func aFailureWithoutWordsGetsAGenericReason() {
        #expect(UpdateEverythingMachine.failureText(nil) == UpdateEverythingMachine.updateFailed)
        #expect(UpdateEverythingMachine.failureText("") == UpdateEverythingMachine.updateFailed)
        #expect(UpdateEverythingMachine.failureText("disk full") == "disk full")
        #expect(!UpdateEverythingMachine.updateFailed.isEmpty)
    }

    @Test func withoutABundleIDTheLaunchCheckDoesNotRunAndNoWindowRefuses() throws {
        #expect(UpdateEverythingDaemon.journalURL(bundleID: nil) == nil)
        #expect(UpdateEverythingDaemon.journalURL(bundleID: "") == nil)
        #expect(UpdateEverythingDaemon.journalURL(bundleID: "com.example.app")?.path().contains("com.example.app") == true)

        let suite = "update-everything-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = UpdateEverythingHost(local: { DaemonService() }, remotes: { [] }, daemon: { _ in nil },
                                        installSSH: { _ in }, updateCloud: { _ in false },
                                        updater: UpdaterService(defaults: defaults, enableSparkle: false, recordsUpdates: false),
                                        appVersion: "100", window: { nil }, journal: nil)
        let registry = ActionRegistry()
        // A test or tool host (no bundle ID) never reads or removes the real app's note.
        #expect(!UpdateEverything.bind(into: registry, host: host), "no launch check without a bundle ID")
        // No window to ask in: the action says so instead of doing nothing.
        let refusal = registry.capturingRefusal { registry.perform(UpdateEverything.actionID) }
        #expect(refusal == UpdateEverythingRunner.noWindow)
    }

    @Test func chatsThatCouldNotRestartAreNamedInTheResult() async throws {
        let (journal, cleanup) = Self.journal()
        defer { cleanup() }
        let steps = RecordingSteps()
        steps.threadsLeft["local"] = "spawn claude: permission denied"
        var mac = Self.thisMac
        mac.app = nil

        let outcomes = await UpdateEverythingRunner(journal: journal, appVersion: "100")
            .run(UpdateEverythingPlan(machines: [mac]), continueThreads: true, steps: steps)

        #expect(outcomes.map(\.failure) == [nil], "the agent CLIs did update")
        let summary = try #require(UpdateEverythingOutcome.summary(outcomes), "the result names the chats left behind")
        #expect(summary.contains("This Mac"))
        #expect(summary.contains("spawn claude: permission denied"))
    }

    private static let thisMac = UpdateEverythingMachine(
        id: "local", name: "This Mac", kind: .local, app: UpdateEverythingChange(name: "cmux NEXT", from: "1.0", to: "1.1"),
        harnesses: [UpdateEverythingChange(id: "claude", name: "Claude Code", from: "2.1.296", to: "2.1.299")], runningThreads: 1)
    private static let devbox = UpdateEverythingMachine(
        id: "ssh:devbox", name: "devbox", kind: .ssh, daemon: UpdateEverythingChange(name: "cmux daemon", from: "abc1234", to: "def5678"))

    private static func journal() -> (UpdateEverythingJournal, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "update-everything-\(UUID().uuidString)")
        return (UpdateEverythingJournal(url: folder.appending(path: "update-everything.json")),
                { try? FileManager.default.removeItem(at: folder) })
    }
}

/// A step's failure, in words for the person.
private struct StepFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// The App's update paths, recorded: each step logs what it was asked to do.
@MainActor
private final class RecordingSteps: UpdateEverythingSteps {
    var log: [String] = []
    /// The agent CLIs a machine's daemon lists once it runs the new build.
    var agentsAfterDaemon: [String: [UpdateEverythingChange]] = [:]
    /// Why some of a machine's threads still run the old agent after its update.
    var threadsLeft: [String: String] = [:]
    /// Why a machine's daemon update fails.
    var daemonFailures: [String: String] = [:]
    /// Why the app's update cannot start.
    var installFailure: String?

    func updateDaemon(on machine: UpdateEverythingMachine) async throws {
        log.append("daemon \(machine.id)")
        if let failure = daemonFailures[machine.id] { throw StepFailure(message: failure) }
    }

    func outdatedAgents(on machine: UpdateEverythingMachine) async -> [UpdateEverythingChange] {
        agentsAfterDaemon[machine.id] ?? machine.harnesses
    }

    func updateAgents(on machine: UpdateEverythingMachine, continueThreads: Bool) async throws -> String? {
        let ids = machine.harnesses.compactMap(\.id).joined(separator: ",")
        log.append("agents \(machine.id) \(ids)\(continueThreads ? " continue" : "")")
        return threadsLeft[machine.id]
    }

    func installApp() throws {
        if let installFailure { throw StepFailure(message: installFailure) }
        log.append("install app")
    }
}
