import Foundation
import Testing
@testable import CmuxNextApp

/// Crash-elimination class b (an Objective-C exception escapes Cocoa): the
/// run that dies of an uncaught exception leaves its name, reason and stack,
/// and the next launch's crash report names them. The tests call the
/// writer that NSSetUncaughtExceptionHandler's handler runs, with the test's
/// own folder.
@MainActor @Suite(.serialized)
struct UncaughtExceptionRecorderTests {
    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cmux-run-\(UUID().uuidString)")
    }

    static let range = NSException(name: .rangeException,
                                   reason: "NSMutableRLEArray objectAtIndex:effectiveRange:: Out of bounds", userInfo: nil)

    @Test func anUncaughtExceptionIsNamedByTheNextLaunchAndItsReport() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let crashed = AppRunMarker(directory: folder)
        #expect(await crashed.flush())
        UncaughtExceptionRecorder.record(Self.range, to: folder.appending(path: "run.exception"))

        let next = AppRunMarker(directory: folder)
        let previous = try #require(next.recovery.previous)
        let exception = try #require(previous.exception)
        #expect(exception.name == "NSRangeException")
        #expect(exception.reason.hasPrefix("NSMutableRLEArray"))
        #expect(exception.summary == "NSRangeException: NSMutableRLEArray objectAtIndex:effectiveRange:: Out of bounds")

        let report = CrashRecoveryService(bundleID: "test.recorder", marksRun: false).appReport(previous)
        #expect(report["exception_name"] as? String == "NSRangeException")
        #expect((report["exception_reason"] as? String)?.hasPrefix("NSMutableRLEArray") == true)
        #expect(report["exception_frames"] is [String])
        #expect(await next.flush())
        next.markCleanExit()
    }

    @Test func aCleanExitLeavesNoExceptionForTheNextLaunch() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let run = AppRunMarker(directory: folder)
        #expect(await run.flush())
        UncaughtExceptionRecorder.record(Self.range, to: folder.appending(path: "run.exception"))
        // A quit after an exception was recorded and caught elsewhere: the
        // clean exit removes the record.
        run.markCleanExit()
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "run.exception").path))
        #expect(AppRunMarker(directory: folder).recovery == .clean)
    }

    @Test func aLaterCrashWithoutAnExceptionDoesNotReuseAnOldOne() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = AppRunMarker(directory: folder)
        #expect(await first.flush())
        UncaughtExceptionRecorder.record(Self.range, to: folder.appending(path: "run.exception"))
        // The second run reads the exception, then ends with no exception
        // and no clean exit (a SIGKILL).
        let second = AppRunMarker(directory: folder)
        #expect(second.recovery.previous?.exception != nil)
        #expect(await second.flush())
        let third = AppRunMarker(directory: folder)
        #expect(third.recovery.isRestart)
        #expect(third.recovery.previous?.exception == nil)
        #expect(await third.flush())
        third.markCleanExit()
    }
}
