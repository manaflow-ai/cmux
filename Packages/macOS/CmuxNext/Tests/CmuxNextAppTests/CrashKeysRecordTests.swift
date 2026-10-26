@testable import CmuxNextApp
import CmuxNextCrashReporting
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// The crash keys reach the next launch (p10-stability-207): a crash with the run marker live writes the keys
/// of that moment into `run.crashkeys` from the crash path, and the next launch reads them back scrubbed.
struct CrashKeysRecordTests {
    @Test func aCrashWritesTheRunningActionAndHungThreadsForTheNextLaunch() async throws {
        let directory = CrashChild.directory("crash-keys", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .failure) {
            await CrashKeysChild.crashInsideAnAction()
        }
        let text = try String(contentsOf: directory.appending(path: "run.crashkeys"), encoding: .utf8)
        let keys = try #require(CrashKeys(record: text), "run.crashkeys holds no record: \(text)")
        #expect(keys.snapshot.actionID == CrashKeySlots.stableKey("workspace.new"), "the record names the running action")
        #expect(keys.snapshot.daemonEpoch == 7)
        #expect(keys.snapshot.hungThreadCount == 1)
        #expect(keys.snapshot.hungThread(at: 0)?.kind == 2)
        #expect(!text.contains("4242"), "a thread port never leaves the process: \(text)")
    }

    @Test func aRecordReadBackKeepsOnlyWhatTheCrashPathWrites() throws {
        let planted = "crash_keys action_id=12 path=/Users/someone/secret pane_kind=0x41 cef_state=-1 "
            + "daemon_epoch=99999999999999999999999 token=abc hung_kind_0=300 hung_kind_1=2\n"
        let keys = try #require(CrashKeys(record: planted))
        #expect(keys.snapshot.actionID == 12)
        #expect(keys.snapshot.paneKind == 0)
        #expect(keys.snapshot.cefState == 0)
        #expect(keys.snapshot.daemonEpoch == 0)
        #expect(keys.snapshot.hungThreadCount == 1)
        let values = keys.tags.values.joined(separator: " ")
        #expect(!values.contains("secret") && !values.contains("abc"), "\(keys.tags)")
        #expect(CrashKeys(record: "not a record") == nil)
    }

    @Test func theWrittenLineRoundTripsAndFitsItsBuffer() throws {
        let slots = CrashKeySlots()
        slots.set(.actionID, .max)
        slots.set(.paneKind, .max)
        slots.set(.cefState, .max)
        slots.set(.daemonEpoch, .max)
        for port in 1...UInt32(CrashKeySlots.hungThreadCapacity) { slots.noteHung(CrashKeySlots.HungThread(port: port, kind: .max)) }
        let keys = CrashKeys(slots.snapshot())
        var bytes = [UInt8](repeating: 0, count: CrashKeys.maxRecordBytes)
        let count = bytes.withUnsafeMutableBytes { keys.write(into: $0) }
        #expect(count < CrashKeys.maxRecordBytes)
        #expect(bytes[count - 1] == 0x0A)
        let back = try #require(CrashKeys(record: String(decoding: bytes[..<count], as: UTF8.self)))
        #expect(back.snapshot.actionID == .max)
        #expect(back.snapshot.daemonEpoch == .max)
        #expect(back.snapshot.hungThreadCount == CrashKeySlots.hungThreadCapacity)
    }
}

/// The exit-test child: the app's launch order (the run marker, then the crash keys attached), an action run
/// with a hung thread named, and a bad memory access inside it.
enum CrashKeysChild {
    @MainActor
    static func crashInsideAnAction() async {
        let marker = await CrashChild.markRun("crash-keys")
        let slots = CrashKeySlots()
        CrashReporter.attachCrashKeys(slots)
        slots.set(.daemonEpoch, 7)
        slots.noteHung(CrashKeySlots.HungThread(port: 4242, kind: 2))
        slots.withKey(.actionID, CrashKeySlots.stableKey("workspace.new")) {
            CrashChild.badAccess()
        }
        withExtendedLifetime(marker) {}
    }
}
