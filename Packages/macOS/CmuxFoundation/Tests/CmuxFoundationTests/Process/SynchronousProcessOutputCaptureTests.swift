import Foundation
import Testing

@testable import CmuxFoundation

@Suite("SynchronousProcessOutputCapture")
struct SynchronousProcessOutputCaptureTests {
    private func openFDCount() -> Int? {
        try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    @Test("captures standard output without leaking pipe file descriptors")
    func captureDoesNotLeakPipeFDs() throws {
        guard let baseline = openFDCount() else {
            return
        }

        var maxCount = baseline
        for _ in 0..<200 {
            let output = SynchronousProcessOutputCapture(
                executablePath: "/usr/bin/printf",
                arguments: ["cmux"]
            ).captureStandardOutput()
            #expect(output == "cmux")
            if let current = openFDCount() {
                maxCount = max(maxCount, current)
            }
        }

        guard let finalCount = openFDCount() else {
            return
        }

        #expect(maxCount - baseline <= 8)
        #expect(finalCount - baseline <= 8)
    }
}
