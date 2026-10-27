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
/// host that could not start is not started again.
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
        // The spawn ran in the .system lane's item, never on the main thread.
        #expect(table.sites.filter { $0.kind == .processSpawn }.isEmpty, "posix_spawn ran on the main thread: \(table.sites)")
        #expect(rig.planOnMain.withLock { $0 } == [false])
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
        #expect(rig.planOnMain.withLock { $0.count } == 1)
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
}
#endif
