@testable import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// p08-startup-099: the daemon's and Chromium's startup traces, asked of the app's (`CMUX_TRACE_STARTUP`): files
/// next to the app's that `trace.py` reads the source from, and seconds until the app's trace closes.
@Suite struct StartupTraceChildrenTests {
    private static let second: UInt64 = 1_000_000_000

    private static func trace(file: URL = URL(fileURLWithPath: "/tmp/startup/startup-app.json"), seconds: Double = 5,
                              now: UInt64) -> StartupTrace {
        StartupTrace(configuration: StartupTraceConfiguration(seconds: seconds, file: file), processStartNanos: 2 * second,
                     clock: ManualClock(), now: { now })
    }

    @Test func childFilesSitNextToTheAppsAndNameTheirSource() {
        let harness = StartupTraceConfiguration(file: URL(fileURLWithPath: "/tmp/startup/startup-app.json"))
        #expect(harness.childFile(.daemon).path == "/tmp/startup/startup-daemon.json")
        #expect(harness.childFile(.chromium).path == "/tmp/startup/startup-cef.json")
        let byPid = StartupTraceConfiguration(file: URL(fileURLWithPath: "/h/Library/Logs/cmux/startup-7.json"))
        #expect(byPid.childFile(.daemon).path == "/h/Library/Logs/cmux/startup-7-daemon.json")
        #expect(byPid.childFile(.chromium).path == "/h/Library/Logs/cmux/startup-7-cef.json")
    }

    /// Whole seconds until the app's deadline (process start + its seconds), rounded up, at least 1.
    @Test func secondsLeftUntilTheAppsTraceCloses() throws {
        let early = try #require(Self.trace(now: 2 * Self.second + 1_200_000_000).childTrace(.chromium))
        #expect(early.seconds == 4)
        #expect(early.file.path == "/tmp/startup/startup-cef.json")
        let late = try #require(Self.trace(now: 6 * Self.second + 500_000_000).childTrace(.daemon))
        #expect(late.seconds == 1)
        #expect(late.file.path == "/tmp/startup/startup-daemon.json")
        #expect(Self.trace(now: 0).deadlineNanos == 7 * Self.second) // the daemon's launcher counts from it
    }

    /// A Chromium that starts, or a daemon a reconnect spawns, after the app's trace ended records nothing.
    @Test func noChildTraceAfterTheDeadline() {
        #expect(Self.trace(now: 7 * Self.second).childTrace(.chromium) == nil)
        #expect(Self.trace(now: 9 * Self.second).childTrace(.daemon) == nil)
    }

    @Test func noChildTraceOnceTheAppsTraceClosed() async {
        let file = FileManager.default.temporaryDirectory.appending(path: "startup-children-\(UUID().uuidString)/startup-app.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let trace = Self.trace(file: file, now: 3 * Self.second)
        #expect(trace.childTrace(.chromium) != nil)
        trace.start(writingOn: BackgroundWork(filesWidths: .serial, label: "test.startup-children"))
        trace.close()
        var status = await trace.flush()
        for _ in 0..<500 where !status.closed {
            await Task.yield()
            status = await trace.flush()
        }
        #expect(status.closed)
        #expect(trace.childTrace(.chromium) == nil)
        #expect(trace.childTrace(.daemon) == nil)
    }
}
