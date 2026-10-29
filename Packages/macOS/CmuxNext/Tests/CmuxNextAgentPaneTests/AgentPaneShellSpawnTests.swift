import CmuxNextCompat
import Darwin
import Dispatch
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `AgentPaneShell.run` awaits its spawn on the shell's ``ChildProcessLauncher``: a run
/// whose spawn is in flight holds a slot of the cap, a failed spawn gives it back, and a command still spawning
/// when the pane closes is hung up as soon as it starts. A gate holds the shell's launcher so the spawns stay in
/// flight until the test opens it; main-actor tasks start in the order they are made.
@MainActor @Suite(.serialized)
struct AgentPaneShellSpawnTests {
    @Test func runsWhoseSpawnIsInFlightCountAgainstTheCap() async throws {
        let shell = Self.shell()
        let gate = LauncherGate(shell.launcher)
        defer {
            gate.open()
            shell.terminateAll()
        }
        let starting = (0..<AgentPaneShell.maximumRunning).map { _ in Task { try await shell.run("sleep 30", cwd: nil) } }
        let extra = Task { try await shell.run("sleep 30", cwd: nil) }
        do {
            _ = try await extra.value
            Issue.record("a run past the cap started while \(AgentPaneShell.maximumRunning) spawns were in flight")
        } catch {
            #expect(error as? AgentPaneShell.Failure == .tooMany)
        }
        gate.open()
        for run in starting { _ = try await run.value }
    }

    @Test func aFailedSpawnGivesItsSlotBack() async {
        // Past ARG_MAX: posix_spawn refuses every command with E2BIG.
        let shell = Self.shell(environment: ["CMUX_TEST_PAST_ARG_MAX": String(repeating: "x", count: 4 << 20)])
        for _ in 0...AgentPaneShell.maximumRunning {
            do throws(AgentPaneShell.Failure) {
                _ = try await shell.run("true", cwd: nil)
                Issue.record("a command with an environment past ARG_MAX started")
            } catch {
                guard case .spawnFailed = error else {
                    Issue.record("a failed spawn kept its slot: \(error)")
                    continue
                }
            }
        }
        #expect(!shell.hasRuns)
    }

    @Test func aCommandStillSpawningWhenThePaneClosesIsHungUp() async throws {
        let shell = Self.shell()
        let gate = LauncherGate(shell.launcher)
        defer { gate.open() }
        let starting = Task { try await shell.run("sleep 30", cwd: nil) }
        let closing = Task {
            shell.terminateAll()
            return shell.hasRuns
        }
        #expect(await closing.value, "a command whose spawn is in flight is one of the pane's runs")
        gate.open()
        let id = try await starting.value
        var chunk = try await shell.read(id, after: 0)
        var reads = 1
        while chunk.exit == nil, reads < 3 {
            chunk = try await shell.read(id, after: chunk.next)
            reads += 1
        }
        #expect(chunk.exit?.signal == SIGHUP)
    }

    private static func shell(environment: [String: String] = [:]) -> AgentPaneShell {
        AgentPaneShell(shell: "/bin/sh", environment: environment.merging(["PATH": "/usr/bin:/bin"]) { mine, _ in mine },
                       home: NSTemporaryDirectory())
    }
}

/// Holds a launcher's queue until ``open()``: a spawn queued behind it stays in flight.
private struct LauncherGate {
    private let semaphore = DispatchSemaphore(value: 0)

    init(_ launcher: ChildProcessLauncher) {
        let semaphore = self.semaphore
        launcher.post { semaphore.blockingWait() }
    }

    func open() { semaphore.signal() }
}
