public import AppKit
import Foundation

public extension NSApplication {
    /// Quits from a run-loop callout, not from inside the caller's main-queue job: `before` runs
    /// first, then `NSApp.terminate`. In a process whose app never ran (the Swift test helper),
    /// AppKit's terminate is `exit(0)`: one test's quit ended the whole test run mid-way with
    /// status 0 and hundreds of tests never finished. There it refuses instead, and names the
    /// call site on stderr and in `refusedTerminations`.
    @MainActor
    static func terminateFromRunLoop(fileID: StaticString = #fileID, line: UInt = #line,
                                     before: (@MainActor () -> Void)? = nil) {
        let site = "\(fileID):\(line)"
        // Who asked, read now: inside the callout the stack is only the run loop's.
        let asker = Thread.callStackSymbols
        MainRunLoopBlock.perform {
            guard NSApp.isRunning else {
                refusedTerminations.append(site)
                let stack = asker.joined(separator: "\n")
                FileHandle.standardError.write(Data("NSApp.terminate refused: the app is not running (a test process); asked at \(site) by\n\(stack)\n".utf8))
                return
            }
            before?()
            NSApp.terminate(nil)
        }
    }

    /// Call sites whose quit `terminateFromRunLoop` refused because the app never ran (tests).
    @MainActor static var refusedTerminations: [String] = []
}
