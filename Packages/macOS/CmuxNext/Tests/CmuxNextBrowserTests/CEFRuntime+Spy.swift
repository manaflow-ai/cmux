@testable import CmuxNextBrowser
import Foundation

extension CEFRuntime {
    /// A runtime over a spy `shim`, in the deferred-event mode when this test process runs with
    /// `CMUX_CEF_DEFER_EVENTS=1` (the Q16 run of task 231, plans/cmux-next/chrome-parity/p01-process.md).
    /// The mode serves one mirror cache per process, so that run is `swift test --no-parallel`.
    static func spy(shim: CEFShimLibrary, storage: CEFProfileStorage) -> CEFRuntime {
        CEFRuntime(shim: shim, storage: storage,
                   deferredEvents: CEFDeferredEvents.requested(by: ProcessInfo.processInfo.environment))
    }
}
