@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `app.hangs` (`cmux app hangs`): the main-thread stall counts a Release or Nightly app serves,
/// where `debug.hangs` is DEV-only. Read-only, numbers and code names only.
@Suite struct AppHangsControlTests {
    private func releaseRouter() -> ControlRouter {
        ControlRouter(identity: testIdentity(), executor: CountingExecutor(),
                      configuration: ControlRouter.Configuration(allowsDebugMethods: false))
    }

    private func object(_ result: Result<JSONValue, ControlError>) throws -> [String: JSONValue] {
        guard case .success(.object(let members)) = result else { Issue.record("not an object: \(result)"); return [:] }
        return members
    }

    /// A release router (no `debug.*` methods) still serves `app.hangs`, and drops `debug.hangs`.
    @Test func aReleaseRouterServesIt() {
        let router = releaseRouter()
        #expect(router.method(named: AppHangsControl.method) != nil)
        #expect(router.method(named: "debug.hangs") == nil)
        #expect(!ControlRouter.isDebugMethod(AppHangsControl.method))
    }

    /// Without a watchdog the reply says so, with zero counts.
    @Test func noWatchdogIsZeroCounts() async throws {
        let reply = try object(await releaseRouter().handle(ControlRequest(method: AppHangsControl.method)))
        #expect(reply["installed"] == false)
        #expect(reply["count"] == 0)
        #expect(reply["over_100ms"] == 0)
        #expect(reply["over_250ms"] == 0)
        #expect(reply["records"] == [])
    }

    /// Counts over 100 and 250 ms are cumulative stall counts (busy windows are not stalls); records
    /// are stalls only, newest last, bounded by `limit`, with only the allowed detail keys.
    @Test func countsAndRecordShape() async throws {
        let router = releaseRouter()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false))
        router.attach(watchdog: watchdog)
        for ms in [60, 120, 300, 90, 260] {
            watchdog.log.append(startUptimeNanos: 1, duration: .milliseconds(ms), cpu: .milliseconds(ms / 2), addresses: [],
                                details: ["verdict": "ours", "task_owner": "Test.owner", "url": "https://example.com/private"])
        }
        watchdog.log.append(startUptimeNanos: 1, duration: .milliseconds(900), addresses: [], kind: .busy)
        let reply = try object(await router.handle(ControlRequest(method: AppHangsControl.method, params: ["limit": 2])))
        #expect(reply["count"] == 5)
        #expect(reply["over_100ms"] == 3)
        #expect(reply["over_250ms"] == 2)
        #expect(reply["max_ms"]?.doubleValue == 300)
        #expect(reply["threshold_ms"]?.doubleValue == 50)
        guard case .array(let records)? = reply["records"] else { Issue.record("no records"); return }
        #expect(records.map { $0["duration_ms"]?.doubleValue } == [90, 260])
        guard case .object(let last)? = records.last else { Issue.record("record not an object"); return }
        #expect(Set(last.keys) == ["sequence", "start_uptime_ns", "duration_ms", "cpu_ms", "frames", "verdict", "task_owner"])
        #expect(last["url"] == nil)
    }

    /// The read clears nothing: two reads give the same counts.
    @Test func readingClearsNothing() async throws {
        let router = releaseRouter()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false))
        router.attach(watchdog: watchdog)
        watchdog.log.append(startUptimeNanos: 1, duration: .milliseconds(400), addresses: [])
        let request = ControlRequest(method: AppHangsControl.method, params: ["clear": true])
        let first = try object(await router.handle(request))
        let second = try object(await router.handle(request))
        #expect(first["over_250ms"] == 1)
        #expect(second["over_250ms"] == 1)
        #expect(watchdog.log.summary.count == 1)
    }

    /// The method `cmux app hangs` sends is this one.
    @Test func theCLIReadsThisMethod() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let source = try String(contentsOf: root.appendingPathComponent("cmux-tui/crates/cmux-tui/src/cli/app.rs"), encoding: .utf8)
        let line = try #require(source.split(separator: "\n").first { $0.contains("const APP_HANGS_METHOD: &str = ") })
        #expect(line.split(separator: "\"").dropFirst().first.map(String.init) == AppHangsControl.method)
    }
}
