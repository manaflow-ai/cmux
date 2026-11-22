import AppKit
@testable import CmuxNextApp
import Foundation
import ObjectiveC
import Testing

/// #44899, #44060: AppKit calls `reportException:` from `-[NSApplication run]`'s catch after an
/// Objective-C exception unwound a Swift job, which leaves the runtime's executor record dead. A
/// main-actor-isolated override starts with the runtime's main-actor check, which reads that dead
/// record and segfaults (`swift_task_isMainExecutorImpl` -> `objc_opt_class` at 0x1e), so the
/// exception is never recorded. The override must run no executor check: called through the
/// Objective-C runtime from a thread that is not the main actor's, it must still run to its end
/// (a main-actor entry check traps there).
@Suite struct ReportExceptionIsolationTests {
    @Test func reportExceptionRunsNoMainActorCheck() async {
        // An uninitialized instance: `init` would make it the process's NSApp. Kept for the process
        // (an NSApplication that never ran init must not be deallocated).
        let app = Unmanaged.passRetained(class_createInstance(CmuxApplication.self, 0) as AnyObject)
        let address = UInt(bitPattern: app.toOpaque())
        let returned = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            Thread {
                let target = Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue()
                let exception = NSException(name: NSExceptionName("ReportExceptionIsolationProbe"), reason: "probe")
                _ = target.perform(#selector(NSApplication.reportException(_:)), with: exception)
                done.resume(returning: true)
            }.start()
        }
        #expect(returned)
    }
}
