@testable import CmuxNextApp
import Foundation
import Testing

/// The Mac's display name is read off the main actor and never through
/// DNS (Host.current() blocked launch for ~35 s).
@MainActor
@Suite struct MacNameTests {
    @Test func readRunsOffTheMainThread() async {
        let wasMain = await MacName.resolve { Thread.isMainThread ? "main" : "background" }
        #expect(wasMain == "background")
    }

    @Test func emptyNameFallsBackToTheKernelHostName() async {
        let name = await MacName.resolve { "  " }
        #expect(!name.isEmpty)
        #expect(name == (MacName.kernelHostName().isEmpty ? "Mac" : MacName.kernelHostName()))
    }

    @Test func computerNameIsNotEmpty() async {
        #expect(!(await MacName.computerName()).isEmpty)
    }
}
