import CmuxNextTestExitTrace
import Darwin
import Foundation
import Testing
import XCTest

/// `swift test` runs this bundle twice: its Swift Testing tests in `swiftpm-testing-helper`, then
/// its XCTest phase in Xcode's `xctest` tool, which loads the same bundle. From 2026-11-02 the
/// XCTest phase of CmuxNext suite steps hung for about 10 minutes and then died on signal 6, after
/// every Swift Testing test had passed (aws-m4pro-1, -3, -4, -6, -9, Blacksmith macOS 26). The stack
/// of the hung xctest (aws-m4pro-6, feat 305434be55a1):
///
///     _XCTestMain -> -[XCTestDriver _runTests] -> -[XCTFuture value]
///       -> +[XCTWaiter _synchronouslyWaitForTimeInterval:] -> CFRunLoopRun -> __CFRunLoopDoBlocks
///       -> the run-loop guard's block -> guard_hold_the_main_loop -> CFRunLoopRun (for good)
///
/// XCTest waits for its start-up work with a turn of the main run loop whenever that work is not
/// done yet (there, a Contacts store lookup in xctest failed for 22 s first; on aws-m4pro-1 the
/// same hang came with no Contacts line at all). The run-loop guard
/// (Tests/Support/CmuxNextTestExitTrace) had queued a block that never returns, so that one turn
/// took xctest's main thread and XCTest never ran its suite.
struct XCTestPhaseTests {
    @Test func theRunLoopGuardHoldsOnlyTheSwiftTestingHelper() {
        #expect(cmux_next_test_runloop_guard_holds_in("swiftpm-testing-helper") == 1)
        #expect(cmux_next_test_runloop_guard_holds_in("xctest") == 0)
        #expect(cmux_next_test_runloop_guard_holds_in(nil) == 0)
    }

    /// An XCTest wait in `xctest` must come back: the probe below waits the way XCTest's own
    /// start-up does, in a child `xctest` of this same bundle. On the base the guard held the
    /// child's main thread, and it was killed here at the limit.
    @Test(.timeLimit(.minutes(3)))
    func anXCTestWaitInTheXCTestPhaseReturns() async throws {
        let bundle = try #require(Self.testBundle(), "the test bundle that holds this test")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("xctest-phase-\(UUID().uuidString).log")
        #expect(FileManager.default.createFile(atPath: output.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: output) }
        let log = try FileHandle(forWritingTo: output)
        defer { try? log.close() }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "CmuxNextAppTests.XCTestPhaseRunLoopProbe", bundle.path]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = log
        child.standardError = log
        let ended = AsyncStream<Int32>.makeStream()
        child.terminationHandler = { finished in
            ended.continuation.yield(finished.terminationStatus)
            ended.continuation.finish()
        }
        try child.run()
        let pid = child.processIdentifier

        let status: Int32? = await withTaskGroup(of: Int32?.self) { group in
            group.addTask {
                for await status in ended.stream { return status }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(120))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if status == nil { kill(pid, SIGKILL) }

        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        let tail = String(text.suffix(4000))
        #expect(status == 0, "xctest: \(status.map { "exit \($0)" } ?? "still running after 120 s, killed"); its output ends: \(tail)")
        #expect(text.contains("Executed 1 test, with 0 failures"), "the probe did not run and pass; output ends: \(tail)")
        #expect(!text.contains("holding the main run loop open"), "the run-loop guard held xctest's main thread")
    }

    /// `…/CmuxNextPackageTests.xctest`, from the image that holds the guard's own code.
    private static func testBundle() -> URL? {
        let installed: @convention(c) () -> Int32 = cmux_next_test_runloop_guard_installed
        var info = Dl_info()
        guard dladdr(unsafeBitCast(installed, to: UnsafeRawPointer.self), &info) != 0, let name = info.dli_fname else {
            return nil
        }
        // <bundle>.xctest/Contents/MacOS/<binary>
        let bundle = URL(fileURLWithPath: String(cString: name))
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return bundle.pathExtension == "xctest" ? bundle : nil
    }
}

/// Run by ``XCTestPhaseTests`` in a child `xctest`, and by the XCTest phase of a whole-package
/// `swift test`, where it passes in about 50 ms. It waits on an expectation the way XCTest's
/// start-up does: the wait turns the main run loop until the expectation is met.
final class XCTestPhaseRunLoopProbe: XCTestCase {
    func testAnXCTestWaitReturns() {
        let turned = expectation(description: "the main run loop turned")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { turned.fulfill() }
        wait(for: [turned], timeout: 10)
    }
}
