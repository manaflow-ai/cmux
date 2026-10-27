#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
@testable import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Foundation
import os
import Testing

/// Host mode's one Chromium Host (task p01-process-080) with real child processes: a shell stands in for the host,
/// spawned by the production lane spawner on BackgroundWork's `.system` lane with its control channel on fd 3; each
/// end reaches the main thread as a visible post on the test's MainWorkScheduler (the test runs the main run loop).
/// A SIGKILLed host that said hello reaches `onHostEnded` once, on the main thread, as killed; a host that ends before
/// its hello (a failed start, or a crash while it starts), a clean exit and an end while cmux quits report nothing; a
/// host that could not start is not started again. With crash survival on (task p01-process-150), a host found on the
/// adoption socket that adopted nothing ends before the new host spawns.
@MainActor
@Suite struct ChromiumHostSupervisorTests {
    /// A stand-in host: `/bin/sh -c script`, its control channel on fd 3.
    private static func plan(_ script: String) -> ChromiumHostLaunchPlan {
        ChromiumHostLaunchPlan(configuration: ChromiumHostConfiguration(executable: URL(filePath: "/bin/sh"), arguments: ["-c", script]),
                               remoteShim: URL(filePath: "/nonexistent/libcmux_cef_shim_remote.dylib"), frameworkLocales: ["en.lproj"])
    }

    /// What the supervisor reported: each `onHostEnded` (its exit and whether it ran on the main thread), and how
    /// many ends its observers saw.
    @MainActor private final class Reports {
        var reported: [(exit: BrowserProcessExit, onMain: Bool)] = []
        private(set) var ends = 0

        func end() {
            ends += 1
        }

        /// Runs the main run loop, where the supervisor's posted ends arrive, until the observers saw `count` ends
        /// (or 10 s); `onHostEnded` runs in the same task, right after them.
        func untilEnds(_ count: Int) {
            let end = Date(timeIntervalSinceNow: 10)
            while ends < count, Date() < end { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005)) }
        }
    }

    /// A supervisor over the lane spawner, and whether each spawn's plan read (inside the lane item) ran on main.
    private struct Rig {
        let supervisor: ChromiumHostSupervisor
        let planOnMain: OSAllocatedUnfairLock<[Bool]>
        let reports = Reports()

        init(_ script: String) {
            let planOnMain = OSAllocatedUnfairLock<[Bool]>(initialState: [])
            let work = BackgroundWork(label: "test.chromium-host-supervisor")
            let mainWork = MainWorkScheduler(budget: MainFrameBudget())
            let plan = ChromiumHostSupervisorTests.plan(script)
            supervisor = ChromiumHostSupervisor(spawner: ChromiumHostLaneSpawner(work: work, mainWork: mainWork, fencesResizes: false) {
                planOnMain.withLock { $0.append(Thread.isMainThread) }
                return plan
            })
            self.planOnMain = planOnMain
            let reports = reports
            supervisor.onHostEnded = { exit in reports.reported.append((exit, Thread.isMainThread)) }
            supervisor.observeHostEnds { reports.end() }
        }
    }

    @Test func aKilledHostReachesOnHostEndedOnceOnMainAsKilled() async throws {
        let rig = Rig("exec /bin/cat <&3 >&3")
        let table = BlockingViolationTable(mode: .record)
        let attachment = try await BlockingViolationTable.$scoped.withValue(table) { try await rig.supervisor.attachment() }
        defer { Darwin.close(attachment.controlFD) }
        await table.flush()
        // The spawn ran in the .system lane's item, never on the main thread; so did the launch's adoption try
        // (task p01-process-150), which reads the plan first: with crash survival off it declines a leftover host.
        #expect(table.sites.filter { $0.kind == .processSpawn }.isEmpty, "posix_spawn ran on the main thread: \(table.sites)")
        #expect(rig.planOnMain.withLock { $0 } == [false, false])
        #expect(rig.supervisor.adoption == "the host's framework cannot be read", "the stand-in's plan names no framework")
        #expect(attachment.frameworkLocales == ["en.lproj"])
        #expect(attachment.inputRingFD == -1 && attachment.resizeFence == nil)
        // The handed-out descriptor is the host's fd 3: a byte written comes back.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        // SAFETY: setsockopt reads the one timeval `timeout` holds, the length given, during the call.
        _ = unsafe setsockopt(attachment.controlFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 42
        // SAFETY: write and read each touch the one byte `byte` holds, during the call.
        let wrote = unsafe write(attachment.controlFD, &byte, 1)
        byte = 0
        // SAFETY: as above.
        let got = unsafe read(attachment.controlFD, &byte, 1)
        #expect(wrote == 1 && got == 1)
        #expect(byte == 42)

        let pid = try #require(rig.supervisor.hostPID)
        rig.supervisor.hostSaidHello()  // CEFHostStart, once the attach got the host's hello
        #expect(kill(pid, SIGKILL) == 0)
        rig.reports.untilEnds(1)
        try #require(rig.reports.reported.count == 1)
        let (exit, onMain) = rig.reports.reported[0]
        #expect(exit.reason == .killed)
        #expect(exit.code == Int(SIGKILL))
        #expect(onMain)
        #expect(rig.supervisor.hostPID == nil)
        #expect(rig.supervisor.exits == ["signal \(SIGKILL)"])
        #expect(kill(pid, 0) == -1, "the ended host was not reaped")
        // The next start serves a new host; its end is reported once more, the first end not again.
        let next = try await rig.supervisor.attachment()
        defer { Darwin.close(next.controlFD) }
        #expect(rig.supervisor.hostsStarted == 2)
        let running = try #require(rig.supervisor.hostPID)
        rig.supervisor.hostSaidHello()
        #expect(kill(running, SIGKILL) == 0)
        rig.reports.untilEnds(2)
        #expect(rig.reports.reported.map(\.exit.reason) == [.killed, .killed])
    }

    @Test func aHostKilledBeforeItsHelloReportsNothing() async throws {
        let rig = Rig("exec /bin/cat <&3 >&3")
        let attachment = try await rig.supervisor.attachment()
        defer { Darwin.close(attachment.controlFD) }
        let pid = try #require(rig.supervisor.hostPID)
        #expect(kill(pid, SIGKILL) == 0)
        rig.reports.untilEnds(1)
        // Its end observers ran (its widgets go), but no page crashed: the host never served one.
        #expect(rig.reports.ends == 1)
        #expect(rig.supervisor.exits == ["signal \(SIGKILL)"])
        #expect(rig.reports.reported.isEmpty)
        // A hello for a host that already ended changes nothing; the next host starts.
        rig.supervisor.hostSaidHello()
        let next = try await rig.supervisor.attachment()
        defer { Darwin.close(next.controlFD) }
        #expect(rig.supervisor.hostsStarted == 2)
    }

    @Test func aCleanExitReportsNothing() async throws {
        let rig = Rig("exit 0")
        let attachment = try await rig.supervisor.attachment()
        defer { Darwin.close(attachment.controlFD) }
        rig.reports.untilEnds(1)
        #expect(rig.supervisor.exits == ["exit 0"])
        #expect(rig.supervisor.hostPID == nil)
        #expect(rig.reports.reported.isEmpty)
    }

    @Test func aHostThatEndsWhileCmuxQuitsReportsNothing() async throws {
        let rig = Rig("exec /bin/cat <&3 >/dev/null")
        rig.supervisor.isQuitting = { true }
        let attachment = try await rig.supervisor.attachment()
        defer { Darwin.close(attachment.controlFD) }
        let running = try #require(rig.supervisor.hostPID)
        rig.supervisor.hostSaidHello()
        #expect(kill(running, SIGKILL) == 0)
        rig.reports.untilEnds(1)
        #expect(rig.supervisor.exits == ["signal \(SIGKILL)"])
        #expect(rig.reports.reported.isEmpty)
    }

    @Test func aHostThatCouldNotStartIsNotStartedAgain() async throws {
        let rig = Rig("exit 65")  // kExitFrameworkLoad
        let attachment = try await rig.supervisor.attachment()
        Darwin.close(attachment.controlFD)
        rig.reports.untilEnds(1)
        // It ended before any hello: a start failure, never a crash of pages.
        #expect(rig.reports.ends == 1)
        #expect(rig.reports.reported.isEmpty)
        #expect(rig.supervisor.startFailure == "could not start (exit 65): the Chromium framework did not load")
        await #expect(throws: ChromiumHostAttachError.cannotStart("could not start (exit 65): the Chromium framework did not load")) {
            _ = try await rig.supervisor.attachment()
        }
        #expect(rig.supervisor.hostsStarted == 1)
        #expect(rig.planOnMain.withLock { $0.count } == 2, "the adoption try and the one spawn")
    }

    @Test func aHostWhoseAttachFailedEndsSilentlyBeforeTheNextOneStarts() async throws {
        let rig = Rig("exec /bin/sleep 60 3<&-")
        let first = try await rig.supervisor.attachment()
        Darwin.close(first.controlFD)  // the attach that took the wire failed
        let old = try #require(rig.supervisor.hostPID)
        let second = try await rig.supervisor.attachment()
        defer { Darwin.close(second.controlFD) }
        // The old host's end observers ran before the new host's wire went out; its SIGKILL is not reported.
        #expect(rig.reports.ends == 1)
        let new = try #require(rig.supervisor.hostPID)
        #expect(new != old)
        #expect(rig.supervisor.hostsStarted == 2)
        rig.supervisor.hostSaidHello()
        try #require(kill(new, SIGKILL) == 0)
        rig.reports.untilEnds(2)
        #expect(rig.reports.reported.map(\.exit.reason) == [.killed])
    }

    /// Task p01-process-150: a process on the adoption socket that adopted nothing (it refused this cmux or gave no
    /// reply; here a stand-in that ends after 1 s) holds the data folder until it ends: the new host spawns only
    /// after, through the lane spawner's real wait for a process this one did not start.
    @Test func theNewHostSpawnsOnlyAfterAHostThatAdoptedNothingEnded() async throws {
        let orphan = try #require(await Task.detached { () -> (pid: pid_t, controlFD: Int32)? in
            try? ChromiumHostLauncher.spawnControlled(executable: URL(filePath: "/bin/sleep"), arguments: ["1"], priority: .userBlocking)
        }.value)
        defer {
            Darwin.close(orphan.controlFD)
            var status: Int32 = 0
            // SAFETY: waitpid writes one Int32 into `status` during the call.
            _ = unsafe waitpid(orphan.pid, &status, WNOHANG)
        }
        let real = ChromiumHostLaneSpawner(work: BackgroundWork(label: "test.chromium-host-supervisor.ending"),
                                           mainWork: MainWorkScheduler(budget: MainFrameBudget()), fencesResizes: false) { nil }
        let spawner = EndingSpawner(orphan: orphan.pid, real: real)
        let started = ContinuousClock.now
        _ = try await ChromiumHostSupervisor(spawner: spawner, survivesAppCrash: true).attachment()
        let ended = try #require(spawner.orphanEndedAtSpawn.withLock { $0 })
        #expect(ended, "the new host spawned while the host found on the socket still ran")
        #expect(ContinuousClock.now - started >= .milliseconds(800))
    }

    /// Adopts nothing from `orphan`, waits for its end with the lane spawner's real wait, and at its spawn records
    /// whether `orphan` has exited (a child of this test: it stays a zombie until the test reaps it).
    private nonisolated final class EndingSpawner: ChromiumHostSpawning {
        let orphan: pid_t
        let orphanEndedAtSpawn = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        private let real: ChromiumHostLaneSpawner

        init(orphan: pid_t, real: ChromiumHostLaneSpawner) {
            self.orphan = orphan
            self.real = real
        }

        func spawn() async throws(ChromiumHostAttachError) -> ChromiumHostSpawn {
            var info = siginfo_t()
            // SAFETY: waitid writes one siginfo_t into `info` during the call; WNOWAIT leaves the zombie.
            let result = unsafe waitid(P_PID, id_t(orphan), &info, WEXITED | WNOHANG | WNOWAIT)
            orphanEndedAtSpawn.withLock { $0 = result == 0 && info.si_pid == orphan }
            return ChromiumHostSpawn(pid: 999_999, attachment: ChromiumHostAttachment(controlFD: -1, remoteShim: URL(filePath: "/x"),
                                                                                       frameworkLocales: []))
        }
        func watchExit(of pid: pid_t, _ ended: @escaping @MainActor @Sendable (ChromiumHostExit) -> Void) {}
        func reap(_ pid: pid_t) {}
        func kill(_ pid: pid_t) {}
        func adopt(declining: Bool) async -> ChromiumHostAdoption.Outcome {
            .notAdopted(hostPID: orphan, trusted: true, reason: "the host did not answer the offer")
        }
        func awaitAdoptedEnd(of pid: pid_t, limit: Duration, killsAtLimit: Bool) async {
            await real.awaitAdoptedEnd(of: pid, limit: limit, killsAtLimit: killsAtLimit)
        }
    }
}
#endif
