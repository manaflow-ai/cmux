import CmuxNextUpdateEverything
import Foundation
import Testing

/// Update Everything (cx-1mbnu) as a person runs it, through its runner and the update paths the
/// App gives it: every machine updates its daemon, then its agent CLIs with its threads continued,
/// the app's own update comes last behind a relaunch note, and the relaunched app finishes the run.
/// A machine whose chats could not restart says so in the result instead of "Everything is updated".
@MainActor
struct UpdateEverythingRunTests {
    @Test func aRunUpdatesEveryMachineThenTheAppLastAndTheRelaunchFinishesIt() async throws {
        let (journal, cleanup) = Self.journal()
        defer { cleanup() }
        let steps = RecordingSteps()
        steps.agentsAfterDaemon["ssh:devbox"] = [UpdateEverythingChange(id: "codex", name: "Codex", from: "0.1", to: "0.2")]
        let plan = UpdateEverythingPlan(machines: [Self.thisMac, Self.devbox])

        let runner = UpdateEverythingRunner(journal: journal)
        #expect(runner.claim())
        let outcomes = await runner.run(plan, continueThreads: true, steps: steps)
        runner.release()

        #expect(outcomes.map(\.failure) == [nil, nil])
        #expect(UpdateEverythingOutcome.summary(outcomes) == nil, "every machine updated")
        // devbox: its daemon first, then the agent CLIs its new daemon lists, threads continued.
        #expect(steps.log.filter { $0.contains("ssh:devbox") } == ["daemon ssh:devbox", "agents ssh:devbox codex continue"])
        #expect(steps.log.contains("agents local claude continue"))
        // The app's update relaunches, so it is the run's last step.
        #expect(steps.log.last == "install app")

        // The relaunched app waits for devbox, then updates it once more to its newer daemon.
        steps.log.removeAll()
        let again = await UpdateEverythingRunner(journal: journal).finishAfterRelaunch(plan: { ids in
            #expect(ids == ["ssh:devbox"])
            var mac = Self.thisMac
            mac.harnesses = []
            return UpdateEverythingPlan(machines: [mac, Self.devbox])
        }, steps: steps)
        #expect(again?.map(\.failure) == [nil])
        #expect(steps.log.first == "daemon ssh:devbox")
        #expect(!steps.log.contains("install app"), "the app installs once")
        // The note is gone: a third launch finishes nothing.
        #expect(await UpdateEverythingRunner(journal: journal).finishAfterRelaunch(plan: { _ in plan }, steps: steps) == nil)
    }

    @Test func chatsThatCouldNotRestartAreNamedInTheResult() async throws {
        let (journal, cleanup) = Self.journal()
        defer { cleanup() }
        let steps = RecordingSteps()
        steps.threadsLeft["local"] = "spawn claude: permission denied"
        var mac = Self.thisMac
        mac.app = nil

        let outcomes = await UpdateEverythingRunner(journal: journal).run(UpdateEverythingPlan(machines: [mac]), continueThreads: true, steps: steps)

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

/// The App's update paths, recorded: each step logs what it was asked to do.
@MainActor
private final class RecordingSteps: UpdateEverythingSteps {
    var log: [String] = []
    /// The agent CLIs a machine's daemon lists once it runs the new build.
    var agentsAfterDaemon: [String: [UpdateEverythingChange]] = [:]
    /// Why some of a machine's threads still run the old agent after its update.
    var threadsLeft: [String: String] = [:]

    func updateDaemon(on machine: UpdateEverythingMachine) async throws {
        log.append("daemon \(machine.id)")
    }

    func outdatedAgents(on machine: UpdateEverythingMachine) async -> [UpdateEverythingChange] {
        agentsAfterDaemon[machine.id] ?? []
    }

    func updateAgents(on machine: UpdateEverythingMachine, continueThreads: Bool) async throws -> String? {
        let ids = machine.harnesses.compactMap(\.id).joined(separator: ",")
        log.append("agents \(machine.id) \(ids)\(continueThreads ? " continue" : "")")
        return threadsLeft[machine.id]
    }

    func installApp() throws {
        log.append("install app")
    }
}
