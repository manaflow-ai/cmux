import Foundation
import Testing
@testable import CmuxNextBrowser

/// CEF shim callbacks reached off the CEF UI (main) thread refuse instead of
/// trapping in `MainActor.assumeIsolated` (plans/cmux-next/crash-elimination.md, P1b).
@MainActor @Suite struct CEFCallbackThreadTests {
    /// A DevTools key off main goes to the page (0), like a page key off main.
    @Test func devToolsKeyOffMainLetsTheInspectorHaveTheKey() async {
        let callback = cefDevToolsKeyCallback
        let result = await withCheckedContinuation { (done: CheckedContinuation<Int32, Never>) in
            Thread.detachNewThread {
                done.resume(returning: callback(UnsafeMutableRawPointer(bitPattern: 0x10), 1, UnsafeMutableRawPointer(bitPattern: 0x20)))
            }
        }
        #expect(result == 0)
    }
}
