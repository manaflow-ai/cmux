@testable import CmuxNextApp
import AppKit
import Darwin
import Foundation
import Testing

/// `CmuxApplication.reportException(_:)` must run no main-actor check.
///
/// AppKit calls `reportException:` from `-[NSApplication run]` after an
/// Objective-C exception unwound the main thread. When that exception
/// unwound a Swift job, the thread's current-executor record still points
/// into the job's freed frame, and the main-actor check of the override's
/// `@objc` entry point read it and crashed: SIGSEGV in
/// `swift_task_isCurrentExecutorWithFlagsImpl` (NIGHTLY
/// 1.0.0-nightly.4062224162001, four launches in a row on 2026-10-27), before
/// the exception was recorded, so neither the report nor the restart notice
/// named it. A call off the main thread fails the same check, so the child
/// below calls it there: the override must record the exception and return.
struct ReportExceptionChildTests {
    @Test func reportExceptionRecordsTheExceptionWithoutAMainActorCheck() async throws {
        let directory = CrashChild.directory("report-exception", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .success) {
            await ReportExceptionChild.reportOffTheMainThread()
        }
        let previous = try #require(CrashChild.previous(in: directory), "the child left no run.json")
        let exception = try #require(previous.exception, "reportException: wrote no run.exception")
        #expect(exception.name == ReportExceptionChild.name)
        #expect(exception.reason == ReportExceptionChild.reason)
    }
}

/// What the exit-test child runs.
enum ReportExceptionChild {
    static let name = "CmuxReportExceptionTest"
    static let reason = "raised inside a Swift job"

    @MainActor
    static func reportOffTheMainThread() async {
        let marker = await CrashChild.markRun("report-exception")
        // AppKit logs a reported exception and goes on (the user's own setting; the app registers true).
        UserDefaults.standard.register(defaults: [CrashOnExceptions.key: false])
        // The child's process-wide application object, read by the thread below; nothing else touches it.
        nonisolated(unsafe) let app = CmuxApplication.shared
        // A plain NSApplication made first would test AppKit's method, not the override.
        guard app is CmuxApplication else { exit(2) }
        let exception = NSException(name: NSExceptionName(name), reason: reason)
        let selector = #selector(NSApplication.reportException(_:))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread {
                _ = app.perform(selector, with: exception)
                done.resume()
            }.start()
        }
        withExtendedLifetime(marker) {}
    }
}
