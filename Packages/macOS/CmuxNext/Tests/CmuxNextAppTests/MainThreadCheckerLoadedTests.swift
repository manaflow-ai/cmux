import Darwin
import Foundation
import Testing

/// The "AppKit off the main thread" crash class's guard is live: when the suite runner loads
/// Xcode's Main Thread Checker (scripts/ci/run_swift_test_bundle.py sets
/// CMUX_MAIN_THREAD_CHECKER_EXPECTED), libMainThreadChecker.dylib is in this test process. A run
/// that silently lost the checker (a moved dylib, a stripped DYLD_INSERT_LIBRARIES) would report
/// zero violations and prove nothing. Without the variable (a local `swift test`) it does nothing.
@Suite
struct MainThreadCheckerLoadedTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_MAIN_THREAD_CHECKER_EXPECTED"] == "1",
                   "the suite runner did not load the Main Thread Checker"))
    func theMainThreadCheckerIsInTheTestProcess() {
        let images = (0 ..< _dyld_image_count()).compactMap { _dyld_get_image_name($0).map { String(cString: $0) } }
        #expect(images.contains { $0.hasSuffix("/libMainThreadChecker.dylib") },
                "DYLD_INSERT_LIBRARIES=\(ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] ?? "unset")")
    }
}
